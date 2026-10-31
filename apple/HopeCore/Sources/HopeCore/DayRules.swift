import Foundation

/// A day as the person lives it: from wake-up to bedtime, not midnight to midnight (rebuild-plan 10 E).
/// A port of the desktop's `src/lib/useToday.ts` (PR #21), so every device puts a record on the same day.
///
/// Everything in the enum is a pure function of the `day` rows, the default times and the clock; the
/// `LocalStore` extension below looks the rows and the settings up.
public enum DayRules {
    /// Device-local settings the desktop writes under the same keys (never synced). The Apple apps read them
    /// when present and fall back to the defaults.
    public enum SettingKey {
        /// Default wake-up time, 'HH:MM'.
        public static let wakeHm = "wake_hm"
        /// Default bedtime, 'HH:MM'.
        public static let sleepHm = "sleep_hm"
        /// "1" = timetable time counts towards totals (rebuild-plan 13.4); unset / "0" = it doesn't.
        public static let includeSchedule = "stats.include_schedule"
    }

    public static let defaultWakeHm = "07:00"
    public static let defaultSleepHm = "23:00"

    /// The default wake-up and bedtime ('HH:MM'). A malformed value counts as the hard default.
    public struct Defaults: Equatable, Sendable {
        public var wakeHm: String
        public var sleepHm: String

        public init(wakeHm: String = DayRules.defaultWakeHm, sleepHm: String = DayRules.defaultSleepHm) {
            self.wakeHm = wakeHm
            self.sleepHm = sleepHm
        }

        public static let standard = Defaults()
    }

    /// The two times of one `day` row; `nil` = not recorded.
    public struct Times: Equatable, Sendable {
        public var wakeMs: Int64?
        public var sleepMs: Int64?

        public init(wakeMs: Int64? = nil, sleepMs: Int64? = nil) {
            self.wakeMs = wakeMs
            self.sleepMs = sleepMs
        }
    }

    private static let dayMs: Int64 = 86_400_000

    // MARK: - Dates and clock times

    /// 'YYYY-MM-DD' of `date` in `calendar` (the `day.date` key, like the desktop's `dateKey`).
    public static func key(of date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Local midnight of a 'YYYY-MM-DD' key; `nil` if malformed or not a real date.
    public static func date(of key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
            let date = calendar.date(from: DateComponents(year: y, month: m, day: d))
        else { return nil }
        // The calendar rolls 2026-02-30 over into March; only a key that comes back unchanged is a date.
        return self.key(of: date, calendar: calendar) == key ? date : nil
    }

    /// Local midnight `days` days away from `date`'s day (calendar math, so DST-safe).
    public static func shift(_ date: Date, days: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    /// Epoch ms of an 'HH:MM' wall-clock time on the local day of `day`; `nil` if malformed. Hours run
    /// 0–24, so "24:30" is half past midnight the next day, as on the desktop.
    public static func atClock(_ hm: String, on day: Date, calendar: Calendar = .current) -> Int64? {
        let parts = hm.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let h = Int(parts[0]), let m = Int(parts[1]), (0...24).contains(h), (0...59).contains(m)
        else { return nil }
        var c = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: day))
        c.hour = h % 24
        c.minute = m
        guard let base = calendar.date(from: c) else { return nil }
        return ms(h == 24 ? (calendar.date(byAdding: .day, value: 1, to: base) ?? base) : base)
    }

    private static func clock(_ hm: String, fallback: String, on day: Date, calendar: Calendar) -> Int64 {
        atClock(hm, on: day, calendar: calendar) ?? atClock(fallback, on: day, calendar: calendar)
            ?? ms(calendar.startOfDay(for: day))
    }

    /// The default wake-up on `day`.
    public static func defaultWake(on day: Date, defaults: Defaults = .standard, calendar: Calendar = .current) -> Int64 {
        clock(defaults.wakeHm, fallback: defaultWakeHm, on: day, calendar: calendar)
    }

    /// The default bedtime of `day`, after its default wake-up: a bedtime at or before the wake-up ("01:00"
    /// with a 09:00 wake-up) falls past midnight.
    public static func defaultSleep(on day: Date, defaults: Defaults = .standard, calendar: Calendar = .current) -> Int64 {
        let sleep = clock(defaults.sleepHm, fallback: defaultSleepHm, on: day, calendar: calendar)
        return sleep <= defaultWake(on: day, defaults: defaults, calendar: calendar) ? sleep + dayMs : sleep
    }

    // MARK: - The rules

    /// Today as lived: local midnight of the day the small hours still belong to. Until the midpoint between
    /// the default bedtime and the next default wake-up (03:00 with 23:00 / 07:00), an unclosed yesterday is
    /// still today — unless today has a wake-up recorded, or yesterday a bedtime that has passed.
    ///
    /// - Parameters:
    ///   - today: the `day` row of the calendar day containing `now`, if any.
    ///   - yesterday: the row of the calendar day before, if any.
    public static func livedToday(
        now: Int64, today: Times?, yesterday: Times?, defaults: Defaults = .standard, calendar: Calendar = .current
    ) -> Date {
        let calendarDay = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1000))
        let yesterdayDay = shift(calendarDay, days: -1, calendar: calendar)
        let nightMidpoint =
            (defaultSleep(on: yesterdayDay, defaults: defaults, calendar: calendar)
                + defaultWake(on: calendarDay, defaults: defaults, calendar: calendar)) / 2
        let yesterdaySlept = yesterday?.sleepMs.map { $0 <= now } ?? false
        let stillYesterday = now < nightMidpoint && today?.wakeMs == nil && !yesterdaySlept
        return stillYesterday ? yesterdayDay : calendarDay
    }

    /// The records of `day`: after the night before's bedtime, until its own. Today runs on to `now` (or to
    /// midnight, whichever is later); a past day with no bedtime recorded closes at the default one, so it
    /// never swallows the next day's records.
    ///
    /// - Parameters:
    ///   - times: the `day` row of `day`, if any.
    ///   - previous: the row of the day before, if any.
    ///   - isToday: whether `day` is today as lived (`livedToday`).
    public static func range(
        of day: Date, times: Times?, previous: Times?, isToday: Bool, now: Int64, defaults: Defaults = .standard,
        calendar: Calendar = .current
    ) -> (from: Int64, to: Int64) {
        let calendarDay = LocalStore.dayRange(of: day, calendar: calendar)
        let closes = times?.sleepMs ?? (isToday ? now : defaultSleep(on: day, defaults: defaults, calendar: calendar))
        return (max(calendarDay.from, previous?.sleepMs ?? 0), max(calendarDay.to, closes))
    }
}

// MARK: - Looking the rows up

extension LocalStore {
    /// The default wake-up and bedtime: the desktop's settings when this device has them, else 07:00 / 23:00.
    public func dayDefaults() -> DayRules.Defaults {
        DayRules.Defaults(
            wakeHm: setting(DayRules.SettingKey.wakeHm) ?? DayRules.defaultWakeHm,
            sleepHm: setting(DayRules.SettingKey.sleepHm) ?? DayRules.defaultSleepHm)
    }

    /// The `day` row keyed 'YYYY-MM-DD', if it exists and is not deleted.
    public func day(_ key: String) -> DayRecord? {
        guard let d = try? DayRecord.find(key, in: context), d.deletedMs == nil else { return nil }
        return d
    }

    private func dayTimes(_ day: Date, calendar: Calendar) -> DayRules.Times? {
        self.day(DayRules.key(of: day, calendar: calendar)).map { DayRules.Times(wakeMs: $0.wakeMs, sleepMs: $0.sleepMs) }
    }

    /// Today as lived (rebuild-plan 10 E), as local midnight; see `DayRules.livedToday`.
    public func livedToday(now: Int64? = nil, calendar: Calendar = .current) -> Date {
        let now = now ?? self.now
        let calendarDay = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1000))
        return DayRules.livedToday(
            now: now, today: dayTimes(calendarDay, calendar: calendar),
            yesterday: dayTimes(DayRules.shift(calendarDay, days: -1, calendar: calendar), calendar: calendar),
            defaults: dayDefaults(), calendar: calendar)
    }

    /// 'YYYY-MM-DD' of today as lived.
    public func livedTodayKey(now: Int64? = nil, calendar: Calendar = .current) -> String {
        DayRules.key(of: livedToday(now: now, calendar: calendar), calendar: calendar)
    }

    /// The records range `[from, to)` of the lived day that starts on `date`'s calendar day; see `DayRules.range`.
    public func dayRecordRange(on date: Date, now: Int64? = nil, calendar: Calendar = .current) -> (from: Int64, to: Int64) {
        let now = now ?? self.now
        let day = calendar.startOfDay(for: date)
        return DayRules.range(
            of: day, times: dayTimes(day, calendar: calendar),
            previous: dayTimes(DayRules.shift(day, days: -1, calendar: calendar), calendar: calendar),
            isToday: day == livedToday(now: now, calendar: calendar), now: now, defaults: dayDefaults(), calendar: calendar)
    }

    /// Entries and total of the lived day starting on `date`'s calendar day (today or any other).
    public func daySummary(
        on date: Date, now: Int64? = nil, calendar: Calendar = .current, includeSchedule: Bool = false
    ) -> DaySummary {
        let now = now ?? self.now
        let range = dayRecordRange(on: date, now: now, calendar: calendar)
        return summary(from: range.from, to: range.to, now: now, includeSchedule: includeSchedule)
    }
}
