import { useTranslation } from "react-i18next";
import { ActivitySummary } from "../components/ActivitySummary";
import { Bars } from "../components/Bars";
import { Duration } from "../components/Duration";
import { Page } from "../components/Page";
import { PeriodNav } from "../components/PeriodNav";
import { scheduleGroup } from "../lib/activity";
import { usePeriod } from "../lib/usePeriod";
import { addWeeks, relativePeriod, weekDays } from "../lib/time";
import { useUi } from "../stores/ui";

export function Week() {
  const { t, i18n } = useTranslation();
  const offset = useUi((s) => s.weekOffset);
  const setOffset = useUi((s) => s.setWeekOffset);
  const openDay = useUi((s) => s.openDay);

  const days = weekDays(addWeeks(new Date(), offset));
  const { now, perDay, totals, todayKey, activities, includeSchedule, scheduleMs } = usePeriod(days);
  const group = scheduleGroup(activities);
  const totalMs = totals.reduce((sum, a) => sum + a.ms, 0);

  const range = new Intl.DateTimeFormat(i18n.language, { month: "long", day: "numeric" }).formatRange(
    days[0]!,
    days[6]!,
  );
  const weekday = new Intl.DateTimeFormat(i18n.language, { weekday: "short" });

  return (
    <Page
      title={offset === 0 ? t("nav.week") : relativePeriod(offset, "week", i18n.language)}
      subtitle={range}
      accessory={<PeriodNav offset={offset} onChange={setOffset} currentLabel={t("period.thisWeek")} />}
    >
      <p className="period-total">
        <Duration ms={totalMs} />
      </p>
      <Bars days={perDay} label={(d) => weekday.format(d)} highlightKey={todayKey} now={now} onOpenDay={openDay} />
      <ActivitySummary
        totals={totals}
        scheduleMs={includeSchedule ? 0 : scheduleMs}
        scheduleName={group?.name}
        scheduleColor={group?.color}
      />
    </Page>
  );
}
