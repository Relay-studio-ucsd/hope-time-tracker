import { useState } from "react";
import { useTranslation } from "react-i18next";
import { activityColorVar, activityName } from "../lib/activity";
import { useUi } from "../stores/ui";
import type { DayTotals } from "../lib/stats";
import { formatDuration } from "../lib/time";
import "./MonthCalendar.css";

interface Props {
  days: DayTotals[];
  /** Short weekday names, Monday first. */
  weekdays: string[];
  todayKey: string;
  now: number;
  /** Opens a day on the Today page; future days stay inert. */
  onOpenDay?: (key: string) => void;
}

/** Month grid, Monday first: date, the day's total, and a thin bar scaled to the month's busiest day. */
export function MonthCalendar({ days, weekdays, todayKey, now, onOpenDay }: Props) {
  const { t } = useTranslation();
  const hoverKey = useUi((s) => s.hoverKey);
  const setHoverKey = useUi((s) => s.setHoverKey);
  const [tooltip, setTooltip] = useState<{ day: string; text: string } | null>(null);
  const show = (day: string, key: string, text: string) => {
    setHoverKey(key);
    setTooltip({ day, text });
  };
  const hide = () => {
    setHoverKey(null);
    setTooltip(null);
  };
  const lead = days.length > 0 ? (days[0]!.date.getDay() + 6) % 7 : 0;
  const peak = Math.max(...days.map((d) => d.totalMs), 1);

  return (
    <div className="calendar">
      {weekdays.map((w, i) => (
        <span key={i} className="calendar-weekday">
          {w}
        </span>
      ))}
      {Array.from({ length: lead }, (_, i) => (
        <span key={`lead-${i}`} />
      ))}
      {days.map((d) => {
        const future = d.date.getTime() > now;
        const open = !future && onOpenDay ? () => onOpenDay(d.key) : undefined;
        const classes = ["calendar-day", d.key === todayKey && "is-today", future && "is-future", open && "is-open"]
          .filter(Boolean)
          .join(" ");
        return (
          // The whole cell takes the click; the date is a button so the keyboard reaches it too.
          <div key={d.key} className={classes} onClick={open}>
            {open ? (
              <button type="button" className="calendar-date tabular">
                {d.date.getDate()}
              </button>
            ) : (
              <span className="calendar-date tabular">{d.date.getDate()}</span>
            )}
            <span className="calendar-total tabular">{d.totalMs > 0 ? formatDuration(d.totalMs) : ""}</span>
            {tooltip?.day === d.key && <span className="chart-tooltip calendar-tooltip">{tooltip.text}</span>}
            {!future && (
              <span className="calendar-bar">
                <span className="calendar-bar-fill" style={{ width: `${(d.totalMs / peak) * 100}%` }}>
                  {d.parts.map((p) => (
                    <span
                      key={p.activityId}
                      className="calendar-piece"
                      data-hover={hoverKey === null ? undefined : hoverKey === p.activityId ? "on" : "off"}
                      tabIndex={0}
                      style={{ flexGrow: p.ms, background: activityColorVar(p.activity?.color) }}
                      onMouseEnter={() => show(d.key, p.activityId, `${activityName(p.activity, t)} · ${formatDuration(p.ms)}`)}
                      onMouseLeave={hide}
                      onFocus={() => show(d.key, p.activityId, `${activityName(p.activity, t)} · ${formatDuration(p.ms)}`)}
                      onBlur={hide}
                    />
                  ))}
                </span>
              </span>
            )}
          </div>
        );
      })}
    </div>
  );
}
