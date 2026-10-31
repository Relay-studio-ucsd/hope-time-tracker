import Foundation
import Testing

@testable import HopeCore

// The wake-up / bedtime day (rebuild-plan 10 E), case for case against the desktop's src/lib/useToday.ts.

@MainActor
@Suite("Day rules: wake-up to bedtime")
struct DayRulesTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    let h: Int64 = 3_600_000

    /// Epoch ms of a wall-clock time in October 2026.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    /// Local midnight of a day in October 2026.
    func date(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day))! }

    func dayRow(_ day: Int, wake: Int64? = nil, sleep: Int64? = nil) -> DayRecord {
        DayRecord(
            date: String(format: "2026-10-%02d", day), wakeMs: wake, sleepMs: sleep, utcOffsetMin: 480, updatedMs: 1,
            deviceId: "d")
    }

    @Test func clockTimesKeysAndDefaults() throws {
        #expect(DayRules.key(of: date(5), calendar: cal) == "2026-10-05")
        #expect(DayRules.key(of: Date(timeIntervalSince1970: Double(at(5, 23, 59)) / 1000), calendar: cal) == "2026-10-05")
        #expect(DayRules.date(of: "2026-10-05", calendar: cal) == date(5))
        #expect(DayRules.date(of: "2026-13-05", calendar: cal) == nil)
        #expect(DayRules.date(of: "2026-02-30", calendar: cal) == nil, "the calendar would roll it into March")
        #expect(DayRules.date(of: "today", calendar: cal) == nil)
        #expect(DayRules.shift(date(5), days: -1, calendar: cal) == date(4))

        #expect(DayRules.atClock("07:00", on: date(20), calendar: cal) == at(20, 7))
        #expect(DayRules.atClock("7:05", on: date(20), calendar: cal) == at(20, 7, 5))
        #expect(DayRules.atClock("24:30", on: date(20), calendar: cal) == at(21, 0, 30), "24:xx is the next day, as on the desktop")
        #expect(DayRules.atClock("25:00", on: date(20), calendar: cal) == nil)
        #expect(DayRules.atClock("7:5", on: date(20), calendar: cal) == nil)
        #expect(DayRules.atClock("07:60", on: date(20), calendar: cal) == nil)
        #expect(DayRules.atClock("", on: date(20), calendar: cal) == nil)

        #expect(DayRules.defaultWake(on: date(20), calendar: cal) == at(20, 7))
        #expect(DayRules.defaultSleep(on: date(20), calendar: cal) == at(20, 23))
        let late = DayRules.Defaults(wakeHm: "09:00", sleepHm: "01:00")
        #expect(DayRules.defaultSleep(on: date(20), defaults: late, calendar: cal) == at(21, 1), "a bedtime before the wake-up is past midnight")
        let broken = DayRules.Defaults(wakeHm: "nope", sleepHm: "")
        #expect(DayRules.defaultWake(on: date(20), defaults: broken, calendar: cal) == at(20, 7), "malformed settings fall back")
        #expect(DayRules.defaultSleep(on: date(20), defaults: broken, calendar: cal) == at(20, 23))

        // The store reads the desktop's keys, else the defaults.
        let db = try device("d")
        #expect(db.dayDefaults() == .standard)
        try db.saveSettings([DayRules.SettingKey.wakeHm: "08:00", DayRules.SettingKey.sleepHm: "00:30"])
        #expect(db.dayDefaults() == DayRules.Defaults(wakeHm: "08:00", sleepHm: "00:30"))
    }

    @Test func theSmallHoursBelongToYesterdayUntilTheMidpoint() throws {
        let db = try device("d")
        let a = try db.addActivity(0, "A")
        // 22:00 on the 20th → 01:00 on the 21st, then 01:30–02:00.
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(20, 22), endMs: at(21, 1)) }
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(21, 1, 30), endMs: at(21, 2)) }

        // 02:00, nobody pressed Sleep: still the 20th, whose records run on to now.
        let two = at(21, 2)
        #expect(db.livedToday(now: two, calendar: cal) == date(20))
        #expect(db.livedTodayKey(now: two, calendar: cal) == "2026-10-20")
        let range = db.dayRecordRange(on: date(20), now: two, calendar: cal)
        #expect(range.from == at(20, 0) && range.to == two)
        #expect(db.todaySummary(now: two, calendar: cal).totalMs == 3 * h + h / 2)
        #expect(db.daySummary(on: date(20), now: two, calendar: cal).totalMs == 3 * h + h / 2, "the lived day's key gives the same")
        // The 21st has not begun as lived; asked for anyway, it reads from its midnight like any other day.
        #expect(db.daySummary(on: date(21), now: two, calendar: cal).totalMs == h + h / 2)

        // 03:00 is the midpoint between 23:00 and 07:00: a new day …
        let three = at(21, 3)
        #expect(db.livedToday(now: three, calendar: cal) == date(21))
        #expect(db.livedToday(now: three - 1, calendar: cal) == date(20))
        // … and the 20th, now a past day without a bedtime, closes at the default one (midnight at the latest).
        #expect(db.daySummary(on: date(20), now: three, calendar: cal).totalMs == 2 * h)
        #expect(db.todaySummary(now: three, calendar: cal).totalMs == h + h / 2, "the small hours are the new day's")

        // A late sleeper: with 09:00 / 01:00 the midpoint is 05:00.
        try db.saveSettings([DayRules.SettingKey.wakeHm: "09:00", DayRules.SettingKey.sleepHm: "01:00"])
        #expect(db.livedToday(now: at(21, 4, 59), calendar: cal) == date(20))
        #expect(db.livedToday(now: at(21, 5), calendar: cal) == date(21))
    }

    @Test func aRecordedBedtimeOrWakeUpSettlesTheSmallHours() throws {
        let db = try device("d")
        let a = try db.addActivity(0, "A")
        try db.insertRaw(dayRow(20, sleep: at(20, 23, 30)))
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(20, 22), endMs: at(21, 1)) }

        let two = at(21, 2)
        #expect(db.livedToday(now: two, calendar: cal) == date(21), "yesterday went to bed")
        // A day never ends before midnight, early bedtime or not; today starts at midnight (never before its own day).
        let yesterday = db.dayRecordRange(on: date(20), now: two, calendar: cal)
        #expect(yesterday.from == at(20, 0) && yesterday.to == at(21, 0))
        let today = db.dayRecordRange(on: date(21), now: two, calendar: cal)
        #expect(today.from == at(21, 0) && today.to == at(22, 0))
        #expect(db.daySummary(on: date(20), now: two, calendar: cal).totalMs == 2 * h, "up to midnight")
        #expect(db.todaySummary(now: two, calendar: cal).totalMs == h, "the part after midnight is today's")

        // A bedtime still ahead (edited by hand) does not close the day yet.
        #expect(db.livedToday(now: at(20, 23), calendar: cal) == date(20))

        // A wake-up recorded today makes it today, bedtime or not.
        let db2 = try device("d")
        try db2.insertRaw(dayRow(21, wake: at(21, 1, 45)))
        #expect(db2.livedToday(now: at(21, 2), calendar: cal) == date(21))
    }

    @Test func aPastDayWithoutABedtimeClosesAtTheDefaultOne() throws {
        let db = try device("d")
        let a = try db.addActivity(0, "A")
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(20, 22), endMs: at(20, 23, 30)) }
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(21, 0, 30), endMs: at(21, 1)) }
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(21, 9), endMs: at(21, 10)) }

        let now = at(25, 12)
        let range = db.dayRecordRange(on: date(20), now: now, calendar: cal)
        #expect(range.from == at(20, 0) && range.to == at(21, 0), "23:00 is before midnight, so midnight")
        #expect(db.daySummary(on: date(20), now: now, calendar: cal).totalMs == h + h / 2)
        #expect(db.daySummary(on: date(21), now: now, calendar: cal).totalMs == h + h / 2, "the 21st keeps its own small hours")
        #expect(db.daySummary(on: date(25), now: now, calendar: cal).totalMs == 0)

        // A default bedtime past midnight stretches a past day into the next.
        try db.saveSettings([DayRules.SettingKey.wakeHm: "09:00", DayRules.SettingKey.sleepHm: "01:00"])
        #expect(db.dayRecordRange(on: date(20), now: now, calendar: cal).to == at(21, 1))
        #expect(db.daySummary(on: date(20), now: now, calendar: cal).totalMs == 2 * h)
    }

    @Test func aBedtimePastMidnightStretchesTheDayAndClipsTheNext() throws {
        let db = try device("d")
        let a = try db.addActivity(0, "A")
        try db.insertRaw(dayRow(20, wake: at(20, 8), sleep: at(21, 1, 30)))
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(21, 0, 30), endMs: at(21, 1)) }
        // Straddles the bedtime: half an hour on each side.
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(21, 1), endMs: at(21, 2)) }
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(21, 9), endMs: at(21, 10)) }

        // 01:00: yesterday's bedtime (01:30) has not come, so the small hours are still the 20th's.
        #expect(db.livedToday(now: at(21, 1), calendar: cal) == date(20))
        // 02:00: it has.
        let two = at(21, 2)
        #expect(db.livedToday(now: two, calendar: cal) == date(21))
        let the20th = db.dayRecordRange(on: date(20), now: two, calendar: cal)
        #expect(the20th.from == at(20, 0) && the20th.to == at(21, 1, 30))
        let the21st = db.dayRecordRange(on: date(21), now: two, calendar: cal)
        #expect(the21st.from == at(21, 1, 30) && the21st.to == at(22, 0), "today starts where last night ended")
        #expect(db.daySummary(on: date(20), now: two, calendar: cal).totalMs == h, "00:30–01:00 and 01:00–01:30")
        #expect(db.todaySummary(now: two, calendar: cal).totalMs == h / 2 + h, "01:30–02:00 and the morning")
        let entries = db.todaySummary(now: two, calendar: cal).entries
        #expect(entries.map(\.durationMs) == [h / 2, h], "the straddling record shows only its part inside")
    }

    @Test func aPlainDayIsTheCalendarDay() throws {
        // No rows, midday: the lived day is the calendar day and the old behaviour holds.
        let db = try device("d")
        let a = try db.addActivity(0, "A")
        try db.at(1) { _ = try db.addSession(activityId: a, startMs: at(20, 23), endMs: at(21, 1)) }
        let noon = at(21, 12)
        #expect(db.livedToday(now: noon, calendar: cal) == date(21))
        let range = db.dayRecordRange(on: date(21), now: noon, calendar: cal)
        #expect(range.from == at(21, 0) && range.to == at(22, 0))
        #expect(db.todaySummary(now: noon, calendar: cal).totalMs == h, "only the part after midnight")
        #expect(db.daySummary(on: Date(timeIntervalSince1970: Double(at(21, 18)) / 1000), now: noon, calendar: cal).totalMs == h, "any instant of the day will do")
    }
}
