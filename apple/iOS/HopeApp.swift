import HopeCore
import SwiftUI

@main
struct HopeApp: App {
    @State private var model: AppModel
    @State private var watch: PhoneLink
    @State private var away: AwayMonitor
    @State private var breaks: BreakScheduler
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Made at launch: a geofence event or a notification action may start the app in the background.
        _away = State(initialValue: AwayMonitor(model: model))
        // The phone is the last to remind (rebuild-plan 15.5); the watch's claims arrive through PhoneLink.
        let breaks = BreakScheduler(model: model, offsetMs: BreakReminder.phoneOffsetMs)
        _breaks = State(initialValue: breaks)
        let watch = PhoneLink()
        watch.onBreakClaim = { claim in breaks.watchClaimed(claim) }
        // A timer started on the watch: pull it now so the away reminder can anchor and the fallback break
        // reminders get lined up, even though nobody opened this app (rebuild-plan 14.5).
        watch.onTimerBeacon = { _ in model.sync.syncNow() }
        _watch = State(initialValue: watch)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .environment(watch)
                .environment(away)
                .environment(breaks)
                // The interface is colourless; colour belongs to activities (rebuild-plan 4.1).
                .tint(.primary)
        }
        .onChange(of: scenePhase) { _, phase in
            // A full round whenever the app comes to the front (rebuild-plan 12.3).
            if phase == .active {
                model.sync.syncNow()
                away.appActivated()
            }
        }
    }
}
