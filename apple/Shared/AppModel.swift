import HopeCore
import SwiftUI

/// The iPhone's tabs (the watch has none).
enum RootTab: Hashable {
    case today, statistics, activities, settings
}

/// The app's single source of truth: the local store, sync, and the timer actions both apps offer.
@MainActor
@Observable
final class AppModel {
    let store: LocalStore
    let sync: SyncService
    /// The last failed action, shown as an alert.
    var failure: String?
    /// The iPhone tab on screen.
    var tab: RootTab = .today
    /// The day the Today tab shows, 'YYYY-MM-DD'; `nil` = today as lived (rebuild-plan 10 E).
    var viewedDay: String?

    init() {
        let store: LocalStore
        do {
            store = try LocalStore()
        } catch {
            // Never leave the user without a timer: run on an in-memory store and say so.
            print("Hope: could not open the local store: \(error)")
            store = try! LocalStore(inMemory: true)
        }
        self.store = store
        sync = SyncService(store: store, config: SupabaseConfig.fromBundle())
        sync.start()
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { failure = String(describing: error) }
    }

    func start(_ activityId: String) { perform { try store.start(activityId: activityId) } }
    func pause() { perform { try store.pause() } }
    func resume() { perform { try store.resume() } }
    func stop() { perform { try store.stop() } }

    func createActivity(name: String, color: ActivityColor) {
        perform { try store.createActivity(name: name, color: color) }
    }

    /// Shows a day on the Today tab, like a day tapped in the desktop's week or month view.
    func openDay(_ key: String) {
        viewedDay = key
        tab = .today
    }

    /// The person picked a tab. Picking Today — again, or from another tab — lands on today as lived; only
    /// `openDay` carries a past day across (the desktop's sidebar does the same).
    func selectTab(_ tab: RootTab) {
        if tab == .today { viewedDay = nil }
        self.tab = tab
    }
}

/// Localized sync errors (same wording as the desktop's `sync.error.*`).
func message(for error: SyncError) -> String {
    switch error.code {
    case .notConfigured: String(localized: "This build has no sync server.")
    case .signedOut: String(localized: "Not signed in.")
    case .network: String(localized: "Can't reach the sync server. Hope will keep trying.")
    case .invalidCredentials: String(localized: "Wrong email or password.")
    case .emailNotConfirmed: String(localized: "Confirm your email first: check your inbox for the link.")
    case .userAlreadyExists: String(localized: "An account with this email already exists. Sign in instead.")
    case .weakPassword: String(localized: "Choose a longer password.")
    case .rateLimited: String(localized: "Too many attempts. Try again in a few minutes.")
    case .sessionExpired: String(localized: "Your sign-in has expired. Sign in again.")
    case .server, .keychain, .database, .decode:
        String(localized: "Something went wrong: \(error.message)")
    }
}
