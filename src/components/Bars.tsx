import { useState } from "react";
import { useTranslation } from "react-i18next";
import { activityColorVar, activityName } from "../lib/activity";
import type { DayTotals } from "../lib/stats";
import { formatDuration } from "../lib/time";
import { useUi } from "../stores/ui";
import "./Bars.css";

interface Props {
  days: DayTotals[];
  /** Short label under each bar. */
  label: (date: Date) => string;
  highlightKey?: string;
  /** Needed with `onOpenDay`, to keep future days inert. */
  now?: number;
  /** Opens a day on the Today page. */
  onOpenDay?: (key: string) => void;
}

const MAX_HEIGHT = 160;
// rebuild-plan 11.3: every piece at least 2px tall, 1px apart.
const MIN_PIECE_PX = 2;

/**
 * Stacked daily bars (rebuild-plan 4.5): 24px wide, 16px apart, total on top. Hovering a piece lights up
 * that activity in every bar and in the summary below (11.2).
 */
export function Bars({ days, label, highlightKey, now, onOpenDay }: Props) {
  const { t } = useTranslation();
  const hoverKey = useUi((s) => s.hoverKey);
  const setHoverKey = useUi((s) => s.setHoverKey);
  const [tooltip, setTooltip] = useState<{ day: string; text: string } | null>(null);
  const peak = Math.max(...days.map((d) => d.totalMs), 1);

  return (
    <div className="bars">
      {days.map((d) => {
        const open = onOpenDay && now !== undefined && d.date.getTime() <= now ? () => onOpenDay(d.key) : undefined;
        const classes = ["bars-col", d.key === highlightKey && "is-highlight", open && "is-open"].filter(Boolean).join(" ");
        return (
          // The whole column takes the click; the label is a button so the keyboard reaches it too.
          <div key={d.key} className={classes} onClick={open}>
            <span className="bars-value tabular">{d.totalMs > 0 ? formatDuration(d.totalMs) : ""}</span>
            <div className="bars-track" style={{ height: MAX_HEIGHT }}>
              <div className="bars-stack">
                {d.parts.map((p) => {
                  const show = () => {
                    setHoverKey(p.activityId);
                    setTooltip({ day: d.key, text: `${activityName(p.activity, t)} · ${formatDuration(p.ms)}` });
                  };
                  const hide = () => {
                    setHoverKey(null);
                    setTooltip(null);
                  };
                  return (
                    <span
                      key={p.activityId}
                      className="bars-piece"
                      data-hover={hoverKey === null ? undefined : hoverKey === p.activityId ? "on" : "off"}
                      tabIndex={0}
                      style={{
                        height: Math.max((p.ms / peak) * MAX_HEIGHT, MIN_PIECE_PX),
                        background: activityColorVar(p.activity?.color),
                      }}
                      onMouseEnter={show}
                      onMouseLeave={hide}
                      onFocus={show}
                      onBlur={hide}
                    />
                  );
                })}
              </div>
              {tooltip?.day === d.key && <span className="chart-tooltip bars-tooltip">{tooltip.text}</span>}
            </div>
            {open ? (
              <button type="button" className="bars-label">
                {label(d.date)}
              </button>
            ) : (
              <span className="bars-label">{label(d.date)}</span>
            )}
          </div>
        );
      })}
    </div>
  );
}
