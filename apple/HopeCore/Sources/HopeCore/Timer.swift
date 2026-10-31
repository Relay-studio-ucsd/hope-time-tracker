import Foundation
import SwiftData

/// Errors from local operations (the Swift side of the Rust `Error`).
public enum StoreError: Error, Equatable {
    case notFound(String)
    case invalid(String)
}

/// At most one of the two is set (same shape as the Rust `TimerState`).
public struct TimerState {
    public var running: SessionRecord?
    public var paused: SessionRecord?
}

/// A top-level activity with its sub-activities, both in the user's sort order.
public struct ActivityNode: Identifiable {
    public var activity: ActivityRecord
    public var children: [ActivityRecord]
    public var id: String { activity.id }
}

// MARK: - Activities

extension LocalStore {
    /// Live activities ordered by `sort`, then name (bytewise, like SQLite). Archived ones are left out,
    /// and so are children of an archived parent.
    public func activities() -> [ActivityRecord] {
        let all = (try? context.fetch(FetchDescriptor<ActivityRecord>(predicate: #Predicate { $0.deletedMs == nil }))) ?? []
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return all
            .filter { a in
                a.archivedAt == nil && (a.parentId.flatMap { byId[$0] }?.archivedAt == nil)
            }
            .sorted { a, b in
                a.sort != b.sort ? a.sort < b.sort : a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
            }
    }

    /// Top-level activities with their children. A child whose parent is missing (sync may deliver it
    /// later) is treated as top-level, matching the desktop.
    public func activityTree() -> [ActivityNode] {
        let list = activities()
        let ids = Set(list.map(\.id))
        return list
            .filter { a in a.parentId.map { !ids.contains($0) } ?? true }
            .map { root in ActivityNode(activity: root, children: list.filter { $0.parentId == root.id }) }
    }

    public func activity(_ id: String) -> ActivityRecord? {
        guard let a = try? ActivityRecord.find(id, in: context), a.deletedMs == nil else { return nil }
        return a
    }

    /// The live parent of a sub-activity.
    public func parent(of activity: ActivityRecord) -> ActivityRecord? {
        activity.parentId.flatMap { self.activity($0) }
    }

    /// `Parent · Child` for a sub-activity, the name otherwise; `nil` if the activity is unknown.
    public func displayName(activityId: String) -> String? {
        guard let a = activity(activityId) else { return nil }
        if let p = parent(of: a) { return "\(p.name) · \(a.name)" }
        return a.name
    }

    /// Whether time on `activityId` is schedule (class) time: the activity or its parent is a schedule group
    /// (rebuild-plan 13.4). Every schedule group counts, even if sync brought more than one. Unknown
    /// activities are not.
    public func isScheduled(activityId: String) -> Bool {
        guard let a = activity(activityId) else { return false }
        return a.isScheduleGroup || parent(of: a)?.isScheduleGroup == true
    }

    /// Whether time on `activityId` is exercise: the activity or its parent is marked exercise
    /// (rebuild-plan 14.1). Unknown activities are not.
    public func isExercise(activityId: String) -> Bool {
        guard let a = activity(activityId) else { return false }
        return a.isExercise || parent(of: a)?.isExercise == true
    }

    /// Children always show their parent's colour; unknown activities are gray.
    public func color(activityId: String) -> ActivityColor {
        guard let a = activity(activityId) else { return .gray }
        return (parent(of: a) ?? a).palette
    }

    /// Adds an activity at the end of its siblings. A sub-activity takes its parent's colour.
    @discardableResult
    public func createActivity(name: String, color: ActivityColor, parentId: String? = nil) throws -> ActivityRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalid("activity name is empty") }
        var stored = color
        if let parentId {
            guard let parent = activity(parentId) else { throw StoreError.notFound("parent activity") }
            guard parent.parentId == nil else { throw StoreError.invalid("sub-activities cannot have sub-activities") }
            stored = parent.palette
        }
        let siblings = (try? context.fetch(FetchDescriptor<ActivityRecord>(predicate: #Predicate { $0.deletedMs == nil }))) ?? []
        let sort = (siblings.filter { $0.parentId == parentId }.map(\.sort).max() ?? -1) + 1
        let record = ActivityRecord(
            id: UUID().uuidString.lowercased(), name: name, color: stored.rawValue, sort: sort, parentId: parentId,
            updatedMs: now, deviceId: deviceId)
        try write { context.insert(record) }
        return record
    }
}

// MARK: - Timer rules (rebuild-plan 3.1, 9.3; mirrors src-tauri/src/db/session.rs)

extension LocalStore {
    func session(_ id: String) -> SessionRecord? {
        guard let s = try? SessionRecord.find(id, in: context), s.deletedMs == nil else { return nil }
        return s
    }

    private func runningSessions() throws -> [SessionRecord] {
        try context.fetch(
            FetchDescriptor<SessionRecord>(
                predicate: #Predicate { $0.endMs == nil && $0.deletedMs == nil },
                sortBy: [SortDescriptor(\.startMs, order: .reverse)]))
    }

    /// Ends every running session ("one running session, globally") and returns the latest of them.
    private func endRunning(at now: Int64) throws -> SessionRecord? {
        let running = try runningSessions()
        for s in running {
            s.endMs = max(now, s.startMs)
            s.updatedMs = Self.bump(s.updatedMs, now: now)
            s.deviceId = deviceId
            s.dirty = true
        }
        return running.first
    }

    private func begin(activityId: String, continuesId: String?, at now: Int64) throws -> SessionRecord {
        _ = try endRunning(at: now)
        try setSetting(Setting.pausedSessionId, nil)
        let s = SessionRecord(
            id: UUID().uuidString.lowercased(), activityId: activityId, startMs: now, continuesId: continuesId,
            updatedMs: now, deviceId: deviceId)
        context.insert(s)
        return s
    }

    /// Starts timing `activityId`; whatever was running ends now.
    @discardableResult
    public func start(activityId: String) throws -> SessionRecord {
        guard activity(activityId) != nil else { throw StoreError.notFound("activity") }
        let now = self.now
        return try write { try begin(activityId: activityId, continuesId: nil, at: now) }
    }

    /// Pausing ends the running session and remembers it so `resume` can continue the chain.
    @discardableResult
    public func pause() throws -> SessionRecord? {
        let now = self.now
        return try write {
            let ended = try endRunning(at: now)
            if let ended { try setSetting(Setting.pausedSessionId, ended.id) }
            return ended
        }
    }

    /// Starts a new session for the paused activity, linked through `continues_id`.
    @discardableResult
    public func resume() throws -> SessionRecord {
        guard let paused = pausedSession() else { throw StoreError.notFound("paused session") }
        let now = self.now
        return try write { try begin(activityId: paused.activityId, continuesId: paused.id, at: now) }
    }

    @discardableResult
    public func stop() throws -> SessionRecord? {
        let now = self.now
        return try write {
            let ended = try endRunning(at: now)
            try setSetting(Setting.pausedSessionId, nil)
            return ended
        }
    }

    private func pausedSession() -> SessionRecord? {
        guard let id = setting(Setting.pausedSessionId), let s = session(id), s.endMs != nil else { return nil }
        return s
    }

    /// The running session, or else the paused one. The pause is remembered on this device only, like
    /// on the desktop.
    public func timerState() -> TimerState {
        if let running = try? runningSessions().first { return TimerState(running: running, paused: nil) }
        return TimerState(running: nil, paused: pausedSession())
    }

    /// Id of the first segment of the chain ending with `session`: the chain's identity across pauses.
    public func chainRootId(of session: SessionRecord) -> String {
        var root = session.id
        var seen: Set<String> = [session.id]
        var next = session.continuesId
        while let id = next, seen.insert(id).inserted, seen.count <= 1000, let s = self.session(id) {
            root = s.id
            next = s.continuesId
        }
        return root
    }

    /// The latest "Keep Going" on a break reminder anywhere in the chain ending with `session` (rebuild-plan 15.1).
    public func chainBreakAckMs(endingWith session: SessionRecord) -> Int64? {
        var latest = session.breakAckMs
        var seen: Set<String> = [session.id]
        var next = session.continuesId
        while let id = next, seen.insert(id).inserted, seen.count <= 1000, let s = self.session(id) {
            if let ack = s.breakAckMs { latest = max(latest ?? ack, ack) }
            next = s.continuesId
        }
        return latest
    }

    /// "Keep Going" on a break reminder: stamps the running session so every device stops reminding for the
    /// step that was due (rebuild-plan 15.2). Nothing running = nothing to stamp.
    @discardableResult
    public func breakAck() throws -> SessionRecord? {
        guard let running = timerState().running else { return nil }
        let now = self.now
        return try write {
            running.breakAckMs = now
            running.updatedMs = Self.bump(running.updatedMs, now: now)
            running.deviceId = deviceId
            running.dirty = true
            return running
        }
    }

    /// Time in the pause/resume chain ending with `session`, pauses excluded. A running segment counts up to `now`.
    public func chainDuration(endingWith session: SessionRecord, now: Int64) -> Int64 {
        var total: Int64 = 0
        var current: SessionRecord? = session
        var seen = Set<String>()
        while let s = current, seen.insert(s.id).inserted, seen.count <= 1000 {
            total += max(0, (s.endMs ?? now) - s.startMs)
            current = s.continuesId.flatMap { self.session($0) }
        }
        return total
    }
}

// MARK: - A day (rebuild-plan 4.5 timeline; mirrors summarizeDay in src/lib/stats.ts)

/// One row of a day: a pause/resume chain shown as a single entry.
public struct DayEntry: Identifiable, Sendable {
    /// Id of the chain's first session in the range.
    public var id: String
    public var activityId: String
    /// `Parent · Child`; `nil` when the activity is unknown (it may arrive with a later sync).
    public var title: String?
    public var color: ActivityColor
    public var startMs: Int64
    /// `nil` while the last segment is running.
    public var endMs: Int64?
    /// Time inside the range; pauses don't count.
    public var durationMs: Int64
    /// Schedule (class) time: the activity or its parent is the schedule group.
    public var scheduled: Bool
}

public struct DaySummary: Sendable {
    /// Tracked time; schedule time only when asked to include it.
    public var totalMs: Int64
    /// Schedule time, always computed.
    public var scheduleMs: Int64
    /// Every entry, scheduled ones included.
    public var entries: [DayEntry]
}

extension LocalStore {
    /// Sessions overlapping `[from, to)`, including a running one, oldest first.
    public func sessions(from: Int64, to: Int64) -> [SessionRecord] {
        let open = Int64.max
        let d = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.deletedMs == nil && $0.startMs < to && ($0.endMs ?? open) > from },
            sortBy: [SortDescriptor(\.startMs)])
        return (try? context.fetch(d)) ?? []
    }

    /// Local midnight to the next local midnight around `date`.
    nonisolated public static func dayRange(of date: Date, calendar: Calendar = .current) -> (from: Int64, to: Int64) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    /// Entries and total for `[from, to)`. Orphan sessions (unknown activity) count like any other.
    /// Schedule time is left out of `totalMs` unless `includeSchedule` (the desktop's default; the Apple apps
    /// have no switch yet), and always reported in `scheduleMs`.
    public func summary(from: Int64, to: Int64, now: Int64, includeSchedule: Bool = false) -> DaySummary {
        let sessions = self.sessions(from: from, to: to)
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func root(_ s: SessionRecord) -> String {
            var cur = s
            var seen = Set<String>()
            while let prev = cur.continuesId.flatMap({ byId[$0] }), seen.insert(cur.id).inserted { cur = prev }
            return cur.id
        }
        var groups: [String: [SessionRecord]] = [:]
        var order: [String] = []
        for s in sessions {
            let r = root(s)
            if groups[r] == nil { order.append(r) }
            groups[r, default: []].append(s)
        }
        var entries: [DayEntry] = []
        var total: Int64 = 0
        var scheduleTotal: Int64 = 0
        var scheduledById: [String: Bool] = [:]
        for key in order {
            let chain = groups[key]!.sorted { $0.startMs < $1.startMs }
            let first = chain[0]
            let duration = chain.reduce(Int64(0)) { sum, s in
                sum + max(0, min(s.endMs ?? now, to) - max(s.startMs, from))
            }
            let scheduled = scheduledById[first.activityId] ?? isScheduled(activityId: first.activityId)
            scheduledById[first.activityId] = scheduled
            if scheduled { scheduleTotal += duration }
            if !scheduled || includeSchedule { total += duration }
            entries.append(
                DayEntry(
                    id: key, activityId: first.activityId, title: displayName(activityId: first.activityId),
                    color: color(activityId: first.activityId), startMs: first.startMs, endMs: chain.last!.endMs,
                    durationMs: duration, scheduled: scheduled))
        }
        entries.sort { $0.startMs < $1.startMs }
        return DaySummary(totalMs: total, scheduleMs: scheduleTotal, entries: entries)
    }

    /// Today as lived — wake-up to bedtime, the small hours included — not the calendar day (`DayRules`).
    public func todaySummary(
        now: Int64? = nil, calendar: Calendar = .current, includeSchedule: Bool = false
    ) -> DaySummary {
        let now = now ?? self.now
        return daySummary(on: livedToday(now: now, calendar: calendar), now: now, calendar: calendar, includeSchedule: includeSchedule)
    }
}
