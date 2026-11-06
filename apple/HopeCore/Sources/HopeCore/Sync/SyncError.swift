import Foundation

/// Stable reason the UI turns into a localized message. Same codes as the Rust `SyncErrorCode`.
public enum SyncErrorCode: String, Sendable, Codable, Equatable {
    case notConfigured = "not_configured"
    case signedOut = "signed_out"
    /// No connection, DNS failure, timeout, TLS failure.
    case network
    case invalidCredentials = "invalid_credentials"
    case emailNotConfirmed = "email_not_confirmed"
    case userAlreadyExists = "user_already_exists"
    case weakPassword = "weak_password"
    /// The emailed 6-digit code is wrong or has expired.
    case invalidCode = "invalid_code"
    case rateLimited = "rate_limited"
    /// The refresh token was rejected; the user has to sign in again.
    case sessionExpired = "session_expired"
    /// The server answered with an unexpected error.
    case server
    case keychain
    case database
    /// The server sent something we could not read.
    case decode
}

public struct SyncError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: SyncErrorCode
    /// Developer-facing detail.
    public var message: String

    public init(_ code: SyncErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public static func decode(_ message: String) -> SyncError { SyncError(.decode, message) }

    public var description: String { "\(code.rawValue): \(message)" }
}
