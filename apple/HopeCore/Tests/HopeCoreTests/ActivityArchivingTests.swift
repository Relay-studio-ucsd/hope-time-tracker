import Testing
@testable import HopeCore

@MainActor
struct ActivityArchivingTests {
    @Test func archivingPreservesSessionsAndChildArchiveStates() throws {
        let db = try LocalStore(inMemory: true, deviceId: "local")
        db.clock = { 100 }
        let parent = try db.createActivity(name: "Study", color: .blue)
        let math = try db.createActivity(name: "Math", color: .blue, parentId: parent.id)
        let old = try db.createActivity(name: "Old", color: .blue, parentId: parent.id)
        try db.setActivityArchived(old.id, archived: true)
        let finished = try db.start(activityId: math.id)
        db.clock = { 200 }
        _ = try db.stop()
        let running = try db.start(activityId: math.id)
        parent.dirty = false
        let revision = db.revision
        var writes = 0
        db.onLocalWrite = { writes += 1 }
        db.clock = { 300 }
        try db.setActivityArchived(parent.id, archived: true)
        #expect(db.activities().isEmpty)
        #expect(parent.archivedAt == 300 && parent.dirty && parent.deviceId == "local")
        #expect(db.revision == revision + 1 && writes == 1)
        #expect(db.session(finished.id)?.endMs == 200)
        #expect(db.timerState().running?.id == running.id)
        let archived = try db.archivedActivityTree()
        #expect(archived.count == 1 && archived.first?.id == parent.id)
        #expect(Set(archived.flatMap { $0.children.map(\.id) }) == Set([math.id, old.id]))
        try db.setActivityArchived(parent.id, archived: false)
        #expect(Set(db.activities().map(\.id)) == Set([parent.id, math.id]))
        #expect(old.archivedAt != nil)
        #expect(try db.archivedActivityTree().map(\.id) == [old.id])
        try db.setActivityArchived(old.id, archived: false)
        #expect(try db.archivedActivityTree().isEmpty)
    }

    @Test func repeatedArchiveIsANoOpAndChildrenWaitForTheirParent() throws {
        let db = try LocalStore(inMemory: true)
        let parent = try db.createActivity(name: "Study", color: .blue)
        let child = try db.createActivity(name: "Math", color: .blue, parentId: parent.id)
        try db.setActivityArchived(child.id, archived: true)
        try db.setActivityArchived(parent.id, archived: true)
        let timestamp = parent.archivedAt
        let revision = db.revision
        try db.setActivityArchived(parent.id, archived: true)
        #expect(parent.archivedAt == timestamp && db.revision == revision)
        #expect(throws: StoreError.self) {
            try db.setActivityArchived(child.id, archived: false)
        }
        #expect(child.archivedAt != nil && db.revision == revision)
    }

    @Test func missingAndScheduleActivitiesCannotBeChanged() throws {
        let db = try LocalStore(inMemory: true)
        let parent = try db.createActivity(name: "Classes", color: .pink)
        let child = try db.createActivity(name: "Math", color: .pink, parentId: parent.id)
        parent.kind = ActivityRecord.scheduleKind
        parent.archivedAt = 1
        child.archivedAt = 1
        #expect(throws: StoreError.self) {
            try db.setActivityArchived(parent.id, archived: false)
        }
        #expect(throws: StoreError.self) {
            try db.setActivityArchived(child.id, archived: false)
        }
        #expect(throws: StoreError.self) {
            try db.setActivityArchived("missing", archived: true)
        }
        let archived = try db.archivedActivityTree()
        #expect(archived.first?.id == parent.id && archived.first?.children.first?.id == child.id)
        parent.deletedMs = 2
        child.deletedMs = 2
        #expect(try db.archivedActivityTree().isEmpty)
    }
}
