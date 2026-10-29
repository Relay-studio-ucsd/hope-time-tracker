import SwiftUI

struct SettingsView: View {
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Button {
                        showAccount = true
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
        }
    }
}
