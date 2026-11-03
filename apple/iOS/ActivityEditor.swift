import HopeCore
import SwiftUI

struct ActivityEditor: View {
    let activity: ActivityRecord
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: ActivityColor
    @State private var failure: String?

    init(activity: ActivityRecord) {
        self.activity = activity
        _name = State(initialValue: activity.name)
        _color = State(initialValue: activity.palette)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            TextField("Activity name", text: $name)
            if activity.parentId == nil {
                Picker("Color", selection: $color) {
                    ForEach(ActivityColor.allCases, id: \.self) { item in
                        HStack {
                            ActivityDot(color: item)
                            Text(item.localizedName)
                        }
                        .tag(item)
                    }
                }
            }
        }
        .navigationTitle("Edit Activity")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try model.store.updateActivity(activity.id, name: trimmed, color: color)
                        dismiss()
                    } catch {
                        failure = String(describing: error)
                    }
                }
                .disabled(trimmed.isEmpty || model.store.isScheduled(activityId: activity.id))
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
}

