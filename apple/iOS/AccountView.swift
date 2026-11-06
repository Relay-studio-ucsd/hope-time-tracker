import HopeCore
import SwiftUI

/// Sign in / create account / password reset / delete account (rebuild-plan 12.4, 17), plus the two
/// reminder switches, because this is the only settings page so far.
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLink.self) private var watch
    @Environment(AwayMonitor.self) private var away
    @Environment(BreakScheduler.self) private var breaks
    @Environment(\.dismiss) private var dismiss

    /// What the signed-out form is asking for (rebuild-plan 17.5): email + password → the sign-up code →
    /// (forgot) the address to send a reset code to → the reset code + new password.
    enum Mode { case credentials, verify, forgot, reset }

    @State private var mode: Mode = .credentials
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    /// Set while asking whether to merge this device into a different account.
    @State private var pendingSwitch: PendingSwitch?
    @State private var askWatchPassword = false
    @State private var watchPassword = ""
    @State private var confirmDelete = false

    struct PendingSwitch: Identifiable {
        var id: String { email }
        var email: String
        var password: String
        var previous: String?
    }

    var body: some View {
        let sync = model.sync
        NavigationStack {
            Form {
                switch sync.phase {
                case .notConfigured:
                    Section {
                        LabeledContent("Status") { Text("Not configured") }
                    } footer: {
                        Text("This build has no sync server, so everything stays on this iPhone. See apple/README.md to turn sync on.")
                    }
                case .signedOut:
                    signedOutSection
                default:
                    signedInSection(sync)
                }
                awaySection
                breakSection
                if let error {
                    Section { Text(verbatim: error).foregroundStyle(.red) }
                }
                if let note {
                    Section { Text(verbatim: note).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .disabled(busy)
            .alert(
                "Use a Different Account?", isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
                presenting: pendingSwitch
            ) { p in
                // Codes are spent once verified, so the switch always ends in a plain sign-in: the account
                // (which can sign in by then) with its password.
                Button("Merge") {
                    Task {
                        if let outcome = await perform({ try await model.sync.signIn(email: p.email, password: p.password, confirmSwitch: true) }) {
                            await settle(outcome, password: p.password)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                Text("This device last synced with \(p.previous ?? String(localized: "another account")). Its records will be merged into \(p.email). Nothing is deleted.")
            }
            .alert("Connect Apple Watch", isPresented: $askWatchPassword) {
                SecureField("Password", text: $watchPassword)
                Button("Connect") { Task { await connectWatch() } }
                Button("Cancel", role: .cancel) { watchPassword = "" }
            } message: {
                Text("Enter your password once more so the watch gets its own sign-in.")
            }
            .confirmationDialog("Delete this account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(sync.email ?? "") and everything it stored in the cloud will be permanently deleted, and other devices will stop syncing. Records on this iPhone stay.")
            }
        }
    }

    /// The away reminder (rebuild-plan 14.2) lives here because this is the only settings page.
    private var awaySection: some View {
        Section {
            Toggle("Remind me when I walk away", isOn: Binding(get: { away.enabled }, set: { on in Task { await away.setEnabled(on) } }))
            if away.enabled {
                LabeledContent("Location") { Text(verbatim: away.locationStatusText) }
                if away.notificationsDenied {
                    Text("Notifications are off for Hope. Turn them on in Settings.").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("With a timer running, Hope asks whether to stop once you are more than 300 m from where you started it. Exercise activities are left alone. Location needs to be set to Always.")
        }
    }

    /// The break reminder (rebuild-plan 15.5). The watch reminds first; the phone two minutes later as a fallback.
    private var breakSection: some View {
        Section {
            Toggle("Break reminders", isOn: Binding(get: { breaks.enabled }, set: { on in Task { await breaks.setEnabled(on) } }))
            if let status = breaks.statusText {
                Text(verbatim: status).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Every 90 minutes of running time, Hope suggests a break. Exercise and the timetable are left alone. The watch reminds first; the iPhone only if it did not.")
        }
    }

    // MARK: Signed out

    private var emailField: some View {
        TextField("Email", text: $email)
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    /// Six digits; the keyboard offers the code from the email.
    private var codeField: some View {
        TextField("Code", text: $code)
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .onChange(of: code) { _, value in
                let digits = String(value.filter(\.isNumber).prefix(6))
                if digits != value { code = digits }
            }
    }

    private var hasCode: Bool { code.count == 6 }

    @ViewBuilder
    private var signedOutSection: some View {
        switch mode {
        case .credentials:
            Section {
                emailField
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Sign In") { Task { await signIn() } }
                    .disabled(email.isEmpty || password.isEmpty)
                Button("Create Account") { Task { await signUp() } }
                    .disabled(email.isEmpty || password.isEmpty)
                Button("Forgot Password?") { switchMode(.forgot) }
            } footer: {
                Text("Records on this device are merged into the account.")
            }
        case .verify:
            Section {
                codeField
                Button("Confirm") { Task { await verify() } }
                    .disabled(!hasCode)
                Button("Resend Code") { Task { await resend() } }
                Button("Back") { switchMode(.credentials) }
            } footer: {
                Text("Enter the code from the email to finish creating the account.")
            }
        case .forgot:
            Section {
                emailField
                Button("Send Code") { Task { await sendResetCode() } }
                    .disabled(email.isEmpty)
                Button("Back") { switchMode(.credentials) }
            } footer: {
                Text("We'll email a code to reset your password.")
            }
        case .reset:
            Section {
                codeField
                SecureField("New Password", text: $password)
                    .textContentType(.newPassword)
                Button("Reset Password") { Task { await resetPassword() } }
                    .disabled(!hasCode || password.isEmpty)
                Button("Resend Code") { Task { await resend() } }
                Button("Back") { switchMode(.credentials) }
            } footer: {
                Text("At least 8 characters.")
            }
        }
    }

    private func switchMode(_ next: Mode) {
        mode = next
        code = ""
        if next == .credentials || next == .reset { password = "" }
        error = nil
        note = nil
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedInSection(_ sync: SyncService) -> some View {
        Section {
            LabeledContent("Account") { Text(verbatim: sync.email ?? "") }
            LabeledContent("Status") { statusText(sync) }
            Button("Sync Now") { sync.syncNow() }
            if watch.watchAvailable {
                Button("Connect Apple Watch") { askWatchPassword = true }
            }
        } footer: {
            if let e = sync.lastError, sync.phase == .error { Text(verbatim: message(for: e)) }
        }
        Section {
            Button("Sign Out", role: .destructive) {
                Task {
                    await sync.signOut()
                    watch.send(SessionHandoff(tokens: nil))
                    note = String(localized: "Signed out. Your records stay on this device.")
                }
            }
        } footer: {
            Text("Signing out keeps everything on this device.")
        }
        Section {
            Button("Delete Account…", role: .destructive) { confirmDelete = true }
        } footer: {
            Text("Deleting removes the account and its cloud data. Records on this iPhone stay.")
        }
    }

    private func statusText(_ sync: SyncService) -> Text {
        switch sync.phase {
        case .syncing: Text("Syncing…")
        case .error: Text("Can't sync right now")
        default:
            if let ms = sync.lastOkMs {
                Text("Last synced \(Date(timeIntervalSince1970: Double(ms) / 1000), format: .dateTime.hour().minute())")
            } else {
                Text("Syncing…")
            }
        }
    }

    // MARK: Flows (rebuild-plan 17.3)

    /// Runs one account call, showing its error; `nil` when it failed.
    private func perform<T>(_ call: () async throws -> T) async -> T? {
        busy = true
        error = nil
        note = nil
        defer { busy = false }
        do {
            return try await call()
        } catch let e as SyncError {
            error = message(for: e)
        } catch {
            self.error = String(describing: error)
        }
        return nil
    }

    /// Ends a sign-in. `password` is what the account signs in with from now on (needed for the watch
    /// hand-off and for the "different account" merge).
    private func settle(_ outcome: SignInOutcome, password: String) async {
        switch outcome {
        case .signedIn:
            if watch.watchAvailable { await handOff(email: email, password: password) }
            self.password = ""
            code = ""
            mode = .credentials
        case .confirmSwitch(let previous):
            pendingSwitch = PendingSwitch(email: email, password: password, previous: previous)
        case .checkEmail:
            mode = .verify
            code = ""
            note = String(localized: "We emailed a 6-digit code to \(email).")
        }
    }

    private func signIn() async {
        busy = true
        error = nil
        note = nil
        defer { busy = false }
        do {
            let outcome = try await model.sync.signIn(email: email, password: password)
            await settle(outcome, password: password)
        } catch let e as SyncError {
            error = message(for: e)
            // Sign-up was never finished: the code can still be entered (or sent again).
            if e.code == .emailNotConfirmed {
                mode = .verify
                code = ""
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    private func signUp() async {
        if let outcome = await perform({ try await model.sync.signUp(email: email, password: password) }) {
            await settle(outcome, password: password)
        }
    }

    private func verify() async {
        if let outcome = await perform({ try await model.sync.verifySignUp(email: email, code: code) }) {
            await settle(outcome, password: password)
        }
    }

    private func sendResetCode() async {
        guard await perform({ try await model.sync.requestPasswordReset(email: email) }) != nil else { return }
        mode = .reset
        code = ""
        password = ""
        note = String(localized: "If \(email) has an account, a 6-digit code is on its way.")
    }

    private func resend() async {
        let sent = await perform {
            if mode == .reset {
                try await model.sync.requestPasswordReset(email: email)
            } else {
                try await model.sync.resendSignUpCode(email: email)
            }
        }
        if sent != nil { note = String(localized: "A new code is on its way to \(email).") }
    }

    private func resetPassword() async {
        if let outcome = await perform({ try await model.sync.resetPassword(email: email, code: code, newPassword: password) }) {
            await settle(outcome, password: password)
        }
    }

    private func deleteAccount() async {
        guard await perform({ try await model.sync.deleteAccount() }) != nil else { return }
        watch.send(SessionHandoff(tokens: nil))
        email = ""
        note = String(localized: "Account deleted. Your records stay on this iPhone.")
    }

    /// The watch gets its own session: a second sign-in with the same password (see `SessionHandoff`).
    private func handOff(email: String, password: String) async {
        do {
            watch.send(try await model.sync.makeHandoff(email: email, password: password))
        } catch let e as SyncError {
            error = message(for: e)
        } catch {
            self.error = String(describing: error)
        }
    }

    private func connectWatch() async {
        let password = watchPassword
        watchPassword = ""
        guard let email = model.sync.email else { return }
        busy = true
        defer { busy = false }
        await handOff(email: email, password: password)
        if error == nil { note = String(localized: "Sent to Apple Watch.") }
    }
}
