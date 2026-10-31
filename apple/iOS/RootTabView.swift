import SwiftUI

/// The four iPhone tabs. Today and Settings are real screens; Statistics and
/// Activities are placeholders until those pages are built.
///
/// The selection lives in `AppModel`, so another tab can open a day on Today
/// (`openDay`). Going through `selectTab` rather than binding the property
/// directly lets a tap on the tab already shown (which sets the same value)
/// bring Today back to today.
struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding(get: { model.tab }, set: { model.selectTab($0) })
        TabView(selection: selection) {
            Tab("Today", systemImage: "sun.max", value: .today) {
                TodayView()
            }
            Tab("Statistics", systemImage: "chart.bar", value: .statistics) {
                PlaceholderTab(title: "Statistics", systemImage: "chart.bar")
            }
            Tab("Activities", systemImage: "circle.square", value: .activities) {
                PlaceholderTab(title: "Activities", systemImage: "circle.square")
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
    }
}

/// A tab that is not built yet: the same large title and grouped background as
/// the real tabs, with a system empty state in the middle.
private struct PlaceholderTab: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        NavigationStack {
            List {}
                .overlay {
                    ContentUnavailableView("Coming soon", systemImage: systemImage)
                }
                .navigationTitle(title)
        }
    }
}
