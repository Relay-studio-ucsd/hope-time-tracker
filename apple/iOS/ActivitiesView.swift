import HopeCore
import SwiftUI

struct ActivitiesView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewActivity = false
    @State private var editingActivity: ActivityRecord?

    var body: some View {
        let _ = model.store.revision
        let tree = model.store.activityTree()

        NavigationStack {
            List {
                ForEach(tree) { node in
                    if node.children.isEmpty {
                        activityButton(node.activity)
                    } else {
                        DisclosureGroup {
                            ForEach(node.children) { child in
                                activityButton(child)
                            }
                        } label: {
                            activityButton(node.activity)
                        }
                    }
                }
            }
            .overlay {
                if tree.isEmpty {
                    ContentUnavailableView(
                        "No activities yet",
                        systemImage: "circle.square"
                    )
                }
            }
            .navigationTitle("Activities")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewActivity = true
                    } label: {
                        Label("New Activity", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showNewActivity) {
            NavigationStack {
                NewActivityView { name, color in
                    model.createActivity(name: name, color: color)
                }
            }
        }
        .sheet(item: $editingActivity) { activity in
            NavigationStack {
                ActivityEditor(activity: activity)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.failure != nil },
                set: { if !$0 { model.failure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.failure ?? "")
        }
    }

    private func activityButton(_ activity: ActivityRecord) -> some View {
        Button {
            editingActivity = activity
        } label: {
            ActivityLabel(name: activity.name, color: model.store.color(activityId: activity.id))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(model.store.isScheduled(activityId: activity.id))
    }

}
