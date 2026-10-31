import { useState } from "react";
import { useTranslation } from "react-i18next";
import { History, Plus } from "lucide-react";
import { Duration } from "../components/Duration";
import { Journal } from "../components/Journal";
import { Page } from "../components/Page";
import { PeriodNav } from "../components/PeriodNav";
import { PlanEditor } from "../components/PlanEditor";
import { RecordEditor } from "../components/RecordEditor";
import { Ring, type RingSegment } from "../components/Ring";
import { Timeline } from "../components/Timeline";
import { commands, type Plan } from "../lib/bindings";
import { useQuery } from "../lib/data";
import { activityName, liveActivities } from "../lib/activity";
import { autoLogs, occurrencesOn } from "../lib/plans";
import { useRingWidth } from "../lib/preferences";
import { ringRecords, type DayEntry } from "../lib/stats";
import { DAY, dateKey, dayRange, formatClock, formatDuration, fromDateKey, relativePeriod, shiftDays } from "../lib/time";
import { useNow } from "../lib/useNow";
import { useToday, utcOffsetMin } from "../lib/useToday";
import { useUi } from "../stores/ui";
import { DayTimeEditor } from "../components/DayTimeEditor";
import "./Today.css";

/** Which sheet is open. */
type Editing =
  | { kind: "plan"; plan: Plan | null }
  | { kind: "record"; entry: DayEntry | null }
  | { kind: "day"; which: "wake" | "sleep" }
  | null;

export function Today() {
  const { t, i18n } = useTranslation();
  const timer = useQuery(() => commands.sessionCurrent(), []);
  const now = useNow(timer?.running ? 1000 : 30_000);
  const dayKey = useUi((s) => s.dayKey);
  const setDayKey = useUi((s) => s.setDayKey);
  const day = useToday(now, dayKey);
  const { today, summary, activities, loaded, wakeMs, sleepMs, includeSchedule, scheduleMs, browsing } = day;
  const ringWidth = useRingWidth();
  const [editing, setEditing] = useState<Editing>(null);

  // Days back from today as lived: ‹ › step it one day at a time, the current-period button clears it.
  const lived = fromDateKey(day.livedKey);
  const offset = Math.round((dayRange(today).from_ms - dayRange(lived).from_ms) / DAY);
  const setOffset = (o: number) => setDayKey(o >= 0 ? null : dateKey(new Date(shiftDays(lived.getTime(), o))));

  const key = dateKey(today);
  const plans = useQuery(() => commands.planList({ from: key, to: key }), [key]);
  // Plans whose time has passed and that log themselves now appear as real records instead.
  const occurrences = occurrencesOn(plans ?? [], activities ?? [], today).filter(
    (o) => !(autoLogs(o.plan) && o.endMs <= now),
  );
  const clock = (ms: number) => formatClock(ms, i18n.language);
  const planSegments: RingSegment[] = occurrences.map((o) => ({
    key: o.key,
    group: o.key,
    startMs: o.startMs,
    endMs: o.endMs,
    color: o.activity?.color,
    tooltip: `${activityName(o.activity, t, o.parent)} · ${clock(o.startMs)}–${clock(o.endMs)} · ${formatDuration(o.endMs - o.startMs)}`,
  }));
  const describe = (e: DayEntry) =>
    `${activityName(e.activity, t, e.parent)} · ${clock(e.startMs)}–${e.endMs === null ? t("today.now") : clock(e.endMs)} · ${formatDuration(e.durationMs)}`;
  const live = liveActivities(activities ?? []);

  const dateText = new Intl.DateTimeFormat(i18n.language, {
    month: "long",
    day: "numeric",
    weekday: "long",
  }).format(today);
  const subtitle =
    day.lastNightMs !== null && day.lastNightMs > 0
      ? `${dateText} · ${t("day.sleptLastNight", { duration: formatDuration(day.lastNightMs) })}`
      : dateText;

  const pressButton = async () => {
    const b = day.button;
    if (!b) return;
    const res =
      b.kind === "wake"
        ? await commands.dayWakeNow(b.date, utcOffsetMin())
        : b.kind === "sleep"
          ? await commands.daySleepNow(b.date, utcOffsetMin())
          : await commands.daySet({ ...b.day, sleep_ms: null });
    if (res.status === "error") console.error(res.error);
  };

  return (
    <Page
      title={browsing ? relativePeriod(offset, "day", i18n.language) : t("nav.today")}
      subtitle={subtitle}
      accessory={<PeriodNav offset={offset} onChange={setOffset} currentLabel={t("period.today")} />}
    >
      <section className="today-ring">
        <Ring
          wakeMs={wakeMs}
          sleepMs={sleepMs}
          records={ringRecords(summary.entries, describe, includeSchedule)}
          interactive
          plans={planSegments}
          now={now}
          stroke={ringWidth}
          wakeLabel={formatClock(day.wakeLabelMs, i18n.language)}
          sleepLabel={formatClock(day.sleepLabelMs, i18n.language)}
          onWakeClick={() => setEditing({ kind: "day", which: "wake" })}
          onSleepClick={() => setEditing({ kind: "day", which: "sleep" })}
          sleepSegments={day.sleepSegments}
          slept={day.slept}
        >
          <span className="today-total">
            <Duration ms={summary.totalMs} />
          </span>
          <span className="today-total-label">{day.slept && !browsing ? t("day.rested") : t("today.total")}</span>
        </Ring>
        {/* Timetable time left out of the total still gets a quiet line of its own (rebuild-plan 13.4). */}
        {!includeSchedule && scheduleMs > 0 && (
          <p className="today-schedule tabular">{t("today.schedule", { duration: formatDuration(scheduleMs) })}</p>
        )}
      </section>

      {day.button && (
        <div className="today-day-button">
          <button type="button" className="settings-button" onClick={() => void pressButton()}>
            {day.button.kind === "wake" ? t("day.wake") : day.button.kind === "sleep" ? t("day.sleep") : t("day.undoSleep")}
          </button>
        </div>
      )}

      <div className="today-toolbar">
        <button
          type="button"
          className="today-add"
          disabled={live.length === 0}
          onClick={() => setEditing({ kind: "record", entry: null })}
        >
          <History size={14} aria-hidden />
          {t("record.add")}
        </button>
        <button
          type="button"
          className="today-add"
          disabled={live.length === 0}
          onClick={() => setEditing({ kind: "plan", plan: null })}
        >
          <Plus size={14} aria-hidden />
          {t("plan.add")}
        </button>
      </div>

      {loaded && summary.entries.length === 0 && occurrences.length === 0 ? (
        <p className="today-empty">{browsing ? t("today.emptyPast") : t("today.empty")}</p>
      ) : (
        <Timeline
          entries={summary.entries}
          plans={occurrences}
          includeSchedule={includeSchedule}
          onEntryClick={(entry) => setEditing({ kind: "record", entry })}
          onPlanClick={(plan) => setEditing({ kind: "plan", plan })}
        />
      )}

      <Journal date={key} past={browsing} />

      {editing?.kind === "plan" && (
        <PlanEditor plan={editing.plan} date={today} activities={activities ?? []} onClose={() => setEditing(null)} />
      )}
      {editing?.kind === "day" && (
        <DayTimeEditor
          which={editing.which}
          date={today}
          dateKey={day.key}
          day={day.day}
          currentMs={editing.which === "wake" ? day.wakeLabelMs : day.sleepLabelMs}
          onClose={() => setEditing(null)}
        />
      )}
      {editing?.kind === "record" && (
        <RecordEditor entry={editing.entry} activities={activities ?? []} date={today} onClose={() => setEditing(null)} />
      )}
    </Page>
  );
}
