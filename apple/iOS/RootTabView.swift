import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "clock")
                }

            Text("Statistics coming soon")
                .tabItem {
                    Label("Statistics", systemImage: "chart.bar")
                }

            Text("Activity management coming soon")
                .tabItem {
                    Label("Activities", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
