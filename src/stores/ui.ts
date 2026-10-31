import { create } from "zustand";

export const VIEWS = ["today", "week", "month", "schedule", "activities", "settings"] as const;
export type View = (typeof VIEWS)[number];

interface UiState {
  view: View;
  /** 0 = the current week/month, -1 = the previous one, … */
  weekOffset: number;
  monthOffset: number;
  /** The day the Today page shows: null = today as lived (rebuild-plan 10 E), else a past 'YYYY-MM-DD'. */
  dayKey: string | null;
  /** What the pointer (or keyboard focus) is on, shared by charts and lists (rebuild-plan 11.2). */
  hoverKey: string | null;
  /**
   * Further keys lit by the same hover. A capsule on the Today ring can stand for several timeline
   * rows (rebuild-plan 11.3 merged drawing); hovering it lights all of them.
   */
  hoverAlso: string[];
  setView: (view: View) => void;
  setHoverKey: (key: string | null, also?: string[]) => void;
  setWeekOffset: (offset: number) => void;
  setMonthOffset: (offset: number) => void;
  setDayKey: (key: string | null) => void;
  /** Show one past day on the Today page (from a month cell or a week bar). */
  openDay: (key: string) => void;
}

export const useUi = create<UiState>((set) => ({
  view: "today",
  weekOffset: 0,
  monthOffset: 0,
  dayKey: null,
  hoverKey: null,
  hoverAlso: [],
  // Picking a view in the sidebar always lands on today; only openDay carries a past day across.
  setView: (view) => set({ view, dayKey: null, hoverKey: null, hoverAlso: [] }),
  setHoverKey: (hoverKey, also = []) => set({ hoverKey, hoverAlso: hoverKey === null ? [] : also }),
  setWeekOffset: (weekOffset) => set({ weekOffset: Math.min(0, weekOffset) }),
  setMonthOffset: (monthOffset) => set({ monthOffset: Math.min(0, monthOffset) }),
  setDayKey: (dayKey) => set({ dayKey, hoverKey: null, hoverAlso: [] }),
  openDay: (dayKey) => set({ view: "today", dayKey, hoverKey: null, hoverAlso: [] }),
}));
