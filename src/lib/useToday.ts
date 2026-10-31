import { commands, type Day } from "./bindings";
import { useQuery, useSetting } from "./data";
import {
  DEFAULT_SLEEP,
  DEFAULT_SLEEP_BUTTON_FROM,
  DEFAULT_WAKE,
  DEFAULT_WAKE_BUTTON_UNTIL,
  PREF,
  useIncludeSchedule,
} from "./preferences";
import { summarizeDay } from "./stats";
import { atClock, dateKey, DAY, dayRange, fromDateKey, shiftDays } from "./time";

/** The button under the ring (rebuild-plan 10 E). */
export type DayButton = { kind: "wake"; date: string } | { kind: "sleep"; date: string } | { kind: "undo"; day: Day } | null;

export interface Segment {
  startMs: number;
  endMs: number;
}

/** Minutes east of UTC right now (what `day.utc_offset_min` stores). */
export function utcOffsetMin(): number {
  return -new Date().getTimezoneOffset();
}

const clock = (day: Date, hm: string | null | undefined, fallback: string) =>
  atClock(day, hm ?? fallback) ?? atClock(day, fallback)!;

/**
 * "Today" as the person lives it: one day runs from wake-up to bedtime, so the small hours belong to
 * the day that has not gone to sleep yet. Until the midpoint between the default bedtime and the next
 * default wake-up (03:00 with the 23:00 / 07:00 defaults), an unclosed yesterday is still "today".
 *
 * With `dayKey`, a past day instead: the same shape, but no wake/sleep button, and a day that never
 * recorded a bedtime closes at the default one (rebuild-plan 10 E) instead of running on to now.
 */
export function useToday(now: number, dayKey: string | null = null) {
  const wakeHm = useSetting(PREF.wake);
  const sleepHm = useSetting(PREF.sleep);
  const wakeUntilHm = useSetting(PREF.wakeButtonUntil);
  const sleepFromHm = useSetting(PREF.sleepButtonFrom);
  const includeSchedule = useIncludeSchedule();

  const cal = new Date(now);
  const calKey = dateKey(cal);
  const yesterday = new Date(shiftDays(cal.getTime(), -1));
  const browsed = dayKey === null ? null : fromDateKey(dayKey);
  // Rows from two days before the browsed day (its own and the night before) up to today, so the
  // lived-day rule below can still look at today and yesterday.
  const earliest = browsed !== null && browsed.getTime() < cal.getTime() ? browsed : cal;
  const days = useQuery(
    () => commands.dayList({ from: dateKey(new Date(shiftDays(earliest.getTime(), -2))), to: calKey }),
    [calKey, dayKey],
  );
  const dayOf = (key: string) => days?.find((d) => d.date === key);

  // Default bedtime of a day, after its default wake-up (it may fall past midnight).
  const defaultWakeOf = (d: Date) => clock(d, wakeHm, DEFAULT_WAKE);
  const defaultSleepOf = (d: Date) => {
    const sleep = clock(d, sleepHm, DEFAULT_SLEEP);
    return sleep <= defaultWakeOf(d) ? sleep + DAY : sleep;
  };

  const yDay = dayOf(dateKey(yesterday));
  const calDay = dayOf(calKey);
  const nightMidpoint = (defaultSleepOf(yesterday) + defaultWakeOf(cal)) / 2;
  const yesterdaySlept = yDay?.sleep_ms != null && yDay.sleep_ms <= now;
  const stillYesterday = now < nightMidpoint && calDay?.wake_ms == null && !yesterdaySlept;

  const lived = stillYesterday ? yesterday : cal;
  const livedKey = dateKey(lived);
  const browsing = browsed !== null && dateKey(browsed) !== livedKey;
  const today = browsed !== null && browsing ? browsed : lived;
  const key = dateKey(today);
  const day = dayOf(key);
  const prev = dayOf(dateKey(new Date(shiftDays(today.getTime(), -1))));

  const defaultWake = defaultWakeOf(today);
  const defaultSleep = defaultSleepOf(today);
  const wakeMs = day?.wake_ms ?? null;
  const sleepMs = day?.sleep_ms ?? null;
  const slept = sleepMs !== null && sleepMs <= now;

  // The ring spans whichever is wider: the defaults or what actually happened.
  const ringFrom = Math.min(defaultWake, wakeMs ?? defaultWake);
  const ringTo = Math.max(defaultSleep, sleepMs ?? defaultSleep);
  const sleepSegments: Segment[] = [];
  if (wakeMs !== null && wakeMs > defaultWake) sleepSegments.push({ startMs: defaultWake, endMs: wakeMs });
  if (sleepMs !== null && sleepMs < defaultSleep) sleepSegments.push({ startMs: sleepMs, endMs: defaultSleep });

  // Records of this day: after last night's bedtime, until tonight's. Today runs on to now (or
  // midnight); a past day with no bedtime recorded closes at the default one.
  const calendar = dayRange(today);
  const range = {
    from_ms: Math.max(calendar.from_ms, prev?.sleep_ms ?? 0),
    to_ms: Math.max(calendar.to_ms, sleepMs ?? (browsing ? defaultSleep : now)),
  };
  const sessions = useQuery(() => commands.sessionList(range), [range.from_ms, range.to_ms]);
  const activities = useQuery(() => commands.activityList(true), []);
  const summary = summarizeDay(sessions ?? [], activities ?? [], range, now, includeSchedule);

  const lastNightMs = wakeMs !== null && prev?.sleep_ms != null ? wakeMs - prev.sleep_ms : null;

  let button: DayButton = null;
  if (days !== undefined && !browsing) {
    if (stillYesterday) {
      button = { kind: "sleep", date: key };
    } else if (wakeMs === null && now < clock(today, wakeUntilHm, DEFAULT_WAKE_BUTTON_UNTIL)) {
      button = { kind: "wake", date: key };
    } else if (sleepMs !== null && day) {
      button = { kind: "undo", day };
    } else if (sleepMs === null && now >= clock(today, sleepFromHm, DEFAULT_SLEEP_BUTTON_FROM)) {
      button = { kind: "sleep", date: key };
    }
  }

  return {
    today,
    key,
    /** True when `dayKey` points at a day other than today as lived. */
    browsing,
    /** Today as lived, even while browsing; ‹ › on the Today page step relative to it. */
    livedKey,
    day,
    summary,
    /** Whether timetable time is in `summary.totalMs` (the setting); `summary.scheduleMs` has it either way. */
    includeSchedule,
    scheduleMs: summary.scheduleMs,
    activities,
    loaded: sessions !== undefined,
    /** Ring bounds. */
    wakeMs: ringFrom,
    sleepMs: ringTo,
    /** What the end labels show: the actual time if recorded, the default otherwise. */
    wakeLabelMs: wakeMs ?? defaultWake,
    sleepLabelMs: sleepMs ?? defaultSleep,
    defaultWake,
    defaultSleep,
    sleepSegments,
    slept,
    lastNightMs,
    button,
  };
}
