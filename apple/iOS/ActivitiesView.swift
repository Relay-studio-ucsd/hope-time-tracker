import HopeCore
import SwiftUI

struct ActivitiesView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewActivity = false

    var body: some View {
        let _ = model.store.revision
        let tree = model.store.activityTree()

        NavigationStack {
            List {
                ForEach(tree) { node in
                    if node.children.isEmpty {
                        ActivityLabel(
                            name: node.activity.name,
                            color: node.activity.palette
                        )
                    } else {
                        DisclosureGroup {
                            ForEach(node.children) { child in
                                ActivityLabel(
                                    name: child.name,
                                    color: node.activity.palette
                                )
                            }
                        } label: {
                            ActivityLabel(
                                name: node.activity.name,
                                color: node.activity.palette
                            )
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
}
