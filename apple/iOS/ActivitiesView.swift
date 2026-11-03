import HopeCore
import SwiftUI

struct ActivitiesView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewActivity = false
    @State private var editingActivity: ActivityRecord?
    @State private var parentForNewActivity: ActivityRecord?

    var body: some View {
        let _ = model.store.revision
        let tree = model.store.activityTree()

        NavigationStack {
            List {
                ForEach(tree) { node in
                    if node.children.isEmpty {
                        parentRow(node.activity)
                    } else {
                        DisclosureGroup {
                            ForEach(node.children) { child in
                                activityButton(child)
                            }
                        } label: {
                            parentRow(node.activity)
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
        .sheet(item: $parentForNewActivity) { parent in
            NavigationStack {
                NewSubactivityView(parent: parent)
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

    private func parentRow(_ activity: ActivityRecord) -> some View {
        HStack {
            activityButton(activity)
            if activity.parentId == nil && !model.store.isScheduled(activityId: activity.id) {
                Button {
                    parentForNewActivity = activity
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .accessibilityLabel("New Sub-activity")
                .accessibilityHint(Text(verbatim: activity.name))
            }
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
