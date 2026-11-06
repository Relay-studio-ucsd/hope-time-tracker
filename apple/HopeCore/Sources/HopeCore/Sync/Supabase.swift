import Foundation

/// Project settings baked into the app's Info.plist at build time (`HopeSupabaseURL`, `HopeSupabaseAnonKey`,
/// filled from apple/Config/Supabase.generated.xcconfig). Missing or empty = a local-only build.
public struct SupabaseConfig: Sendable, Equatable {
    public var url: String
    public var anonKey: String

    public init?(url: String?, anonKey: String?) {
        let u = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let k = (anonKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded `$(SUPABASE_URL)` means the build had no config at all.
        guard !u.isEmpty, !k.isEmpty, !u.contains("$("), !k.contains("$("), URL(string: u) != nil else { return nil }
        self.url = u.hasSuffix("/") ? String(u.dropLast()) : u
        self.anonKey = k
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> SupabaseConfig? {
        SupabaseConfig(
            url: bundle.object(forInfoDictionaryKey: "HopeSupabaseURL") as? String,
            anonKey: bundle.object(forInfoDictionaryKey: "HopeSupabaseAnonKey") as? String)
    }
}

/// One HTTP exchange. The engine never sees HTTP; this exists so request shapes can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw SyncError(.network, error.localizedDescription)
        }
    }
}

// MARK: - GoTrue (rebuild-plan 12.4)

public struct AuthUser: Codable, Sendable, Equatable {
    public var id: String
    public var email: String?
}

public struct AuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Seconds.
    public var expiresIn: Int64
    public var user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }

    public init(accessToken: String, refreshToken: String, expiresIn: Int64, user: AuthUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.user = user
    }
}

public enum SignUpResult: Sendable, Equatable {
    case signedIn(AuthTokens)
    /// The project requires email confirmation; no session until the emailed code is verified.
    case confirmEmail
}

/// Which emailed code `verify` checks (rebuild-plan 17.3).
public enum CodeKind: String, Sendable {
    case signUp = "signup"
    case recovery
}

/// Email + password auth against `/auth/v1`, request for request the same as `src-tauri/src/sync/http.rs`.
public struct AuthAPI: Sendable {
    public var config: SupabaseConfig
    public var transport: any HTTPTransport

    public init(config: SupabaseConfig, transport: any HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    func request(_ path: String, method: String = "POST", body: [String: String]? = nil, bearer: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "\(config.url)/auth/v1/\(path)")!)
        r.httpMethod = method
        r.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONEncoder().encode(body)
        }
        return r
    }

    public func signIn(email: String, password: String) async throws -> AuthTokens {
        let (status, body) = try await transport.send(
            request("token?grant_type=password", body: ["email": email, "password": password]))
        guard (200..<300).contains(status) else { throw Self.authError(status: status, body: body, refreshing: false) }
        return try Self.parseTokens(body)
    }

    public func signUp(email: String, password: String) async throws -> SignUpResult {
        let (status, body) = try await transport.send(request("signup", body: ["email": email, "password": password]))
        guard (200..<300).contains(status) else { throw Self.authError(status: status, body: body, refreshing: false) }
        return try Self.parseSignUp(body)
    }

    static func parseSignUp(_ body: Data) throws -> SignUpResult {
        guard let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw SyncError.decode("sign-up response")
        }
        if parsed["access_token"] != nil { return .signedIn(try parseTokens(body)) }
        // With "Confirm email" on, the answer is the new user without a session. For an address that is already
        // registered GoTrue answers 200 with a made-up user (so addresses cannot be probed) and sends nothing;
        // the one tell is an empty `identities` list.
        if let identities = parsed["identities"] as? [Any], identities.isEmpty {
            throw SyncError(.userAlreadyExists, "sign-up answered with no identities")
        }
        return .confirmEmail
    }

    /// Checks an emailed 6-digit code. A correct one is spent and answers with a session.
    public func verify(_ kind: CodeKind, email: String, code: String) async throws -> AuthTokens {
        let (status, body) = try await transport.send(
            request("verify", body: ["type": kind.rawValue, "email": email, "token": code]))
        guard (200..<300).contains(status) else { throw Self.authError(status: status, body: body, refreshing: false) }
        return try Self.parseTokens(body)
    }

    /// Sends the sign-up code again.
    public func resendSignUpCode(email: String) async throws {
        try await expectSuccess(request("resend", body: ["type": CodeKind.signUp.rawValue, "email": email]))
    }

    /// Emails a password-reset code. Succeeds whether or not the address has an account.
    public func recover(email: String) async throws {
        try await expectSuccess(request("recover", body: ["email": email]))
    }

    /// Sets a new password for the session behind `accessToken`.
    public func updatePassword(accessToken: String, password: String) async throws {
        try await expectSuccess(request("user", method: "PUT", body: ["password": password], bearer: accessToken))
    }

    private func expectSuccess(_ r: URLRequest) async throws {
        let (status, body) = try await transport.send(r)
        guard (200..<300).contains(status) else { throw Self.authError(status: status, body: body, refreshing: false) }
    }

    /// Deletes the account behind `accessToken` and all of its rows (`delete_account()` in `supabase/schema.sql`).
    /// A 401 comes back as `sessionExpired` so the caller can refresh and retry.
    public func deleteAccount(accessToken: String) async throws {
        var r = URLRequest(url: URL(string: "\(config.url)/rest/v1/rpc/delete_account")!)
        r.httpMethod = "POST"
        r.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("{}".utf8)
        let (status, body) = try await transport.send(r)
        if status == 401 { throw SyncError(.sessionExpired, "access token rejected") }
        guard (200..<300).contains(status) else {
            throw SyncError(.server, "HTTP \(status): \(String(String(decoding: body, as: UTF8.self).prefix(300)))")
        }
    }

    public func refresh(_ refreshToken: String) async throws -> AuthTokens {
        let (status, body) = try await transport.send(
            request("token?grant_type=refresh_token", body: ["refresh_token": refreshToken]))
        guard (200..<300).contains(status) else { throw Self.authError(status: status, body: body, refreshing: true) }
        return try Self.parseTokens(body)
    }

    /// Ends this device's session on the server. Best effort: signing out locally never depends on it.
    public func signOut(accessToken: String) async {
        _ = try? await transport.send(request("logout?scope=local", bearer: accessToken))
    }

    static func parseTokens(_ body: Data) throws -> AuthTokens {
        do {
            return try JSONDecoder().decode(AuthTokens.self, from: body)
        } catch {
            throw SyncError.decode("token response: \(error)")
        }
    }

    /// GoTrue has answered errors in two shapes over the years:
    /// `{"error_code": "...", "msg": "..."}` and `{"error": "...", "error_description": "..."}`.
    static func authError(status: Int, body: Data, refreshing: Bool) -> SyncError {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let field = { (k: String) in parsed[k] as? String ?? "" }
        let code = field("error_code").isEmpty ? field("error") : field("error_code")
        let message = [field("msg"), field("error_description"), field("message")].first { !$0.isEmpty } ?? "HTTP \(status)"
        let kind: SyncErrorCode
        if status == 429 || code.hasPrefix("over_") {
            kind = .rateLimited
        } else if refreshing && (400..<500).contains(status) {
            kind = .sessionExpired
        } else {
            switch code {
            case "invalid_credentials", "invalid_grant": kind = .invalidCredentials
            case "email_not_confirmed": kind = .emailNotConfirmed
            case "user_already_exists", "email_exists": kind = .userAlreadyExists
            case "weak_password": kind = .weakPassword
            case "otp_expired": kind = .invalidCode
            default: kind = .server
            }
        }
        return SyncError(kind, "\(code): \(message)")
    }
}

// MARK: - PostgREST (rebuild-plan 12.3)

/// `SyncRemote` over HTTPS. Uses the access token from `token(force)`; on a 401 it forces one refresh and retries.
@MainActor
public final class SupabaseRemote: SyncRemote {
    let config: SupabaseConfig
    let transport: any HTTPTransport
    let token: @MainActor (_ force: Bool) async throws -> String

    public init(config: SupabaseConfig, transport: any HTTPTransport, token: @escaping @MainActor (_ force: Bool) async throws -> String) {
        self.config = config
        self.transport = transport
        self.token = token
    }

    func upsertRequest(_ table: SyncTable, rows: [Row]) throws -> URLRequest {
        let cols = table.columns.joined(separator: ",")
        var r = URLRequest(url: URL(string: "\(config.url)/rest/v1/\(table.rawValue)?on_conflict=user_id,\(table.key)&columns=\(cols)")!)
        r.httpMethod = "POST"
        r.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Every row carries every column, so PostgREST never fills a default in for a missing one.
        let full = rows.map { row in Dictionary(uniqueKeysWithValues: table.columns.map { ($0, row[$0] ?? .null) }) }
        r.httpBody = try JSONEncoder().encode(full)
        return r
    }

    func fetchRequest(_ table: SyncTable, after: Int64, limit: Int) -> URLRequest {
        let url = "\(config.url)/rest/v1/\(table.rawValue)?select=*&server_seq=gt.\(after)&order=server_seq.asc&limit=\(limit)"
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "GET"
        return r
    }

    private func call(_ request: URLRequest) async throws -> [Row] {
        var token = try await self.token(false)
        for attempt in 0..<2 {
            var r = request
            r.setValue(config.anonKey, forHTTPHeaderField: "apikey")
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (status, body) = try await transport.send(r)
            if status == 401 && attempt == 0 {
                // Expired or revoked JWT: refresh once and retry.
                token = try await self.token(true)
                continue
            }
            guard (200..<300).contains(status) else {
                let snippet = String(String(decoding: body, as: UTF8.self).prefix(300))
                throw SyncError(.server, "HTTP \(status): \(snippet)")
            }
            do {
                return try JSONDecoder().decode([Row].self, from: body)
            } catch {
                throw SyncError.decode("PostgREST response: \(error)")
            }
        }
        throw SyncError(.sessionExpired, "access token rejected after refresh")
    }

    public func upsert(_ table: SyncTable, rows: [Row]) async throws -> [Row] {
        try await call(try upsertRequest(table, rows: rows))
    }

    public func fetch(_ table: SyncTable, after: Int64, limit: Int) async throws -> [Row] {
        try await call(fetchRequest(table, after: after, limit: limit))
    }
}
