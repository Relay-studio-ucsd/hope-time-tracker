import Foundation
import SwiftData

extension LocalStore {
    /// Saves the name and colour together; children inherit their parent's colour.
    public func updateActivity(_ id: String, name: String, color: ActivityColor) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalid("activity name is empty") }
        guard let activity = activity(id) else { throw StoreError.notFound("activity") }
        guard !isScheduled(activityId: id) else { throw StoreError.invalid("schedule activities are read-only") }
        var resolvedColor = color
        if activity.parentId != nil {
            guard let parent = parent(of: activity) else { throw StoreError.notFound("parent activity") }
            resolvedColor = parent.palette
        }
        try write {
            let children = try context.fetch(FetchDescriptor<ActivityRecord>(
                predicate: #Predicate { $0.parentId == id && $0.deletedMs == nil }
            ))
            activity.name = name
            activity.color = resolvedColor.rawValue
            touch(activity)
            for child in children where child.color != activity.color {
                child.color = activity.color
                touch(child)
            }
        }
    }
}

