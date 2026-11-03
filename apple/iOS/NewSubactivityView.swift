import HopeCore
import SwiftUI

struct NewSubactivityView: View {
    let parent: ActivityRecord
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failure: String?

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section("Parent activity") {
                ActivityLabel(name: parent.name, color: parent.palette)
            }
            Section {
                TextField("Activity name", text: $name)
            }
        }
        .navigationTitle("New Sub-activity")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(trimmed.isEmpty)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: failure ?? "")
        }
    }

    private func add() {
        do {
            guard let current = model.store.activity(parent.id), current.archivedAt == nil else {
                throw StoreError.invalid("parent activity is unavailable")
            }
            guard !model.store.isScheduled(activityId: current.id) else {
                throw StoreError.invalid("schedule activities are read-only")
            }
            try model.store.createActivity(
                name: trimmed, color: current.palette, parentId: current.id
            )
            dismiss()
        } catch {
            failure = String(describing: error)
        }
    }
}
