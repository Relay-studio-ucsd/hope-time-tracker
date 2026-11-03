import Foundation
import SwiftData

extension LocalStore {
    /// Archives only this row. Children of an archived parent are hidden by the activity queries.
    public func setActivityArchived(_ id: String, archived: Bool) throws {
        guard let activity = activity(id) else { throw StoreError.notFound("activity") }
        guard !isScheduled(activityId: id) else {
            throw StoreError.invalid("schedule activities are read-only")
        }
        if !archived, parent(of: activity)?.archivedAt != nil {
            throw StoreError.invalid("restore the parent activity first")
        }
        guard (activity.archivedAt != nil) != archived else { return }
        try write {
            activity.archivedAt = archived ? now : nil
            touch(activity)
        }
    }

    /// Archived parents include all their live children. A separately archived child is its own row.
    public func archivedActivityTree() throws -> [ActivityNode] {
        let all = try context.fetch(FetchDescriptor<ActivityRecord>(
            predicate: #Predicate { $0.deletedMs == nil }
        )).sorted { a, b in
            a.sort != b.sort ? a.sort < b.sort : a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
        }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return all.filter { activity in
            activity.archivedAt != nil &&
                activity.parentId.flatMap { byId[$0] }?.archivedAt == nil
        }.map { root in
            ActivityNode(activity: root, children: all.filter { $0.parentId == root.id })
        }
    }
}
