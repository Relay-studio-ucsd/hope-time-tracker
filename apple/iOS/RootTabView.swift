import SwiftUI

/// The four iPhone tabs. Today and Settings are real screens; Statistics and
/// Activities are placeholders until those pages are built.
struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") {
                TodayView()
            }
            Tab("Statistics", systemImage: "chart.bar") {
                PlaceholderTab(title: "Statistics", systemImage: "chart.bar")
            }
            Tab("Activities", systemImage: "circle.square") {
                PlaceholderTab(title: "Activities", systemImage: "circle.square")
            }
            Tab("Settings", systemImage: "gearshape") {
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
