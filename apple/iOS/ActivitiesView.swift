import HopeCore
import SwiftUI

struct ActivitiesView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewActivity = false
    @State private var editingActivity: ActivityRecord?
    @State private var parentForNewActivity: ActivityRecord?
    @State private var archivedTree: [ActivityNode] = []
    @State private var showArchived = false

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
                if !archivedTree.isEmpty {
                    Section {
                        DisclosureGroup("Archived", isExpanded: $showArchived) {
                            ForEach(archivedTree) { node in
                                archivedRow(node.activity)
                                ForEach(node.children) { child in
                                    activityLabel(child)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if tree.isEmpty && archivedTree.isEmpty {
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
        .onChange(of: model.store.revision, initial: true) { _, _ in
            loadArchived()
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

    private func loadArchived() {
        do {
            archivedTree = try model.store.archivedActivityTree()
        } catch {
            model.failure = String(describing: error)
        }
    }

    private func archivedRow(_ activity: ActivityRecord) -> some View {
        HStack {
            activityLabel(
                activity, name: model.store.displayName(activityId: activity.id)
            )
            .foregroundStyle(.secondary)
            Spacer()
            if !model.store.isScheduled(activityId: activity.id) {
                Button("Restore") {
                    do {
                        try model.store.setActivityArchived(activity.id, archived: false)
                    } catch {
                        model.failure = String(describing: error)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityHint(Text(verbatim: activity.name))
            }
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

    private func activityLabel(_ activity: ActivityRecord, name: String? = nil) -> some View {
        HStack {
            ActivityLabel(
                name: name ?? activity.name,
                color: model.store.color(activityId: activity.id)
            )
            if model.store.isScheduled(activityId: activity.id) {
                Label("Schedule", systemImage: "graduationcap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            } else if model.store.isExercise(activityId: activity.id) {
                Label("Exercise", systemImage: "figure.run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private func activityButton(_ activity: ActivityRecord) -> some View {
        Button {
            editingActivity = activity
        } label: {
            activityLabel(activity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(model.store.isScheduled(activityId: activity.id))
    }

}
