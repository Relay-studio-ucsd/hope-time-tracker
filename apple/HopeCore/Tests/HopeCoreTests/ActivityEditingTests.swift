import Testing
@testable import HopeCore

@MainActor
struct ActivityEditingTests {
    @Test func savesBothFieldsAndUpdatesChildren() throws {
        let db = try LocalStore(inMemory: true, deviceId: "test")
        let parent = try db.createActivity(name: "Study", color: .blue)
        let child = try db.createActivity(name: "Math", color: .blue, parentId: parent.id)
        child.archivedAt = 1
        parent.dirty = false
        child.dirty = false
        let revision = db.revision
        let previous = parent.updatedMs
        db.clock = { 1 }
        try db.updateActivity(parent.id, name: " Reading ", color: .green)
        #expect(parent.name == "Reading" && parent.palette == .green)
        #expect(child.palette == .green && child.archivedAt == 1)
        #expect(parent.dirty && child.dirty && parent.updatedMs > previous)
        #expect(db.revision == revision + 1)
        try db.updateActivity(child.id, name: "Algebra", color: .pink)
        #expect(child.name == "Algebra" && child.palette == .green)
    }

    @Test func rejectsInvalidEditsWithoutChangingData() throws {
        let db = try LocalStore(inMemory: true)
        let activity = try db.createActivity(name: "Study", color: .blue)
        let revision = db.revision
        #expect(throws: StoreError.self) {
            try db.updateActivity(activity.id, name: "   ", color: .green)
        }
        #expect(activity.name == "Study" && activity.palette == .blue)
        #expect(db.revision == revision)
        activity.kind = ActivityRecord.scheduleKind
        #expect(throws: StoreError.self) {
            try db.updateActivity(activity.id, name: "Classes", color: .pink)
        }
        #expect(activity.name == "Study" && activity.palette == .blue)
        #expect(throws: StoreError.self) {
            try db.updateActivity("missing", name: "Missing", color: .blue)
        }
    }
}
