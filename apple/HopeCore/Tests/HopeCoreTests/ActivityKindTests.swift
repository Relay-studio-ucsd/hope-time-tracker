import Testing
@testable import HopeCore

@MainActor
struct ActivityKindTests {
    @Test func exerciseIsSavedAndInheritedWithoutChangingChildKinds() throws {
        let db = try LocalStore(inMemory: true, deviceId: "local")
        let parent = try db.createActivity(name: "Walk", color: .blue)
        let child = try db.createActivity(name: "Park", color: .blue, parentId: parent.id)
        parent.dirty = false
        let previous = parent.updatedMs
        let revision = db.revision
        var writes = 0
        db.onLocalWrite = { writes += 1 }
        db.clock = { 1 }
        try db.updateActivity(parent.id, name: "Walking", color: .green, isExercise: true)
        #expect(parent.name == "Walking" && parent.palette == .green && parent.isExercise)
        #expect(parent.dirty && parent.updatedMs > previous && parent.deviceId == "local")
        #expect(db.revision == revision + 1 && writes == 1)
        #expect(db.isExercise(activityId: child.id) && child.kind == nil)
        try db.updateActivity(child.id, name: "Trail", color: .pink)
        #expect(child.name == "Trail" && child.palette == .green && child.kind == nil)
        #expect(db.isExercise(activityId: child.id))
        try db.updateActivity(parent.id, name: "Walk", color: .blue)
        #expect(parent.isExercise)
        try db.updateActivity(parent.id, name: "Walk", color: .blue, isExercise: false)
        #expect(parent.kind == nil && !db.isExercise(activityId: child.id))
    }

    @Test func invalidEditsDoNotPartiallyChangeAnyFields() throws {
        let db = try LocalStore(inMemory: true)
        let parent = try db.createActivity(name: "Walk", color: .blue)
        let child = try db.createActivity(name: "Park", color: .blue, parentId: parent.id)
        let revision = db.revision
        #expect(throws: StoreError.self) {
            try db.updateActivity(parent.id, name: "   ", color: .pink, isExercise: true)
        }
        #expect(parent.name == "Walk" && parent.palette == .blue && parent.kind == nil)
        #expect(throws: StoreError.self) {
            try db.updateActivity(child.id, name: "Changed", color: .pink, isExercise: true)
        }
        #expect(throws: StoreError.self) {
            try db.updateActivity(child.id, name: "Changed", color: .pink, isExercise: false)
        }
        #expect(child.name == "Park" && child.palette == .blue && child.kind == nil)
        #expect(db.revision == revision)
    }

    @Test func scheduleGroupsAndTheirChildrenStayReadOnly() throws {
        let db = try LocalStore(inMemory: true)
        let parent = try db.createActivity(name: "Classes", color: .pink)
        let child = try db.createActivity(name: "Math", color: .pink, parentId: parent.id)
        parent.kind = ActivityRecord.scheduleKind
        for activity in [parent, child] {
            #expect(throws: StoreError.self) {
                try db.updateActivity(activity.id, name: "Changed", color: .green, isExercise: true)
            }
            #expect(db.isScheduled(activityId: activity.id))
        }
        #expect(parent.kind == ActivityRecord.scheduleKind && child.kind == nil)
        #expect(parent.name == "Classes" && child.name == "Math")
    }
}
