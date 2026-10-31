import { useTranslation } from "react-i18next";
import { ActivitySummary } from "../components/ActivitySummary";
import { MonthCalendar } from "../components/MonthCalendar";
import { Duration } from "../components/Duration";
import { Page } from "../components/Page";
import { PeriodNav } from "../components/PeriodNav";
import { scheduleGroup } from "../lib/activity";
import { usePeriod } from "../lib/usePeriod";
import { addMonths, monthDays, relativePeriod, weekDays } from "../lib/time";
import { useUi } from "../stores/ui";

export function Month() {
  const { t, i18n } = useTranslation();
  const offset = useUi((s) => s.monthOffset);
  const setOffset = useUi((s) => s.setMonthOffset);
  const openDay = useUi((s) => s.openDay);

  const month = addMonths(new Date(), offset);
  const days = monthDays(month);
  const { now, perDay, totals, todayKey, activities, includeSchedule, scheduleMs } = usePeriod(days);
  const group = scheduleGroup(activities);
  const totalMs = totals.reduce((sum, a) => sum + a.ms, 0);

  const title = new Intl.DateTimeFormat(i18n.language, { year: "numeric", month: "long" }).format(month);
  const weekday = new Intl.DateTimeFormat(i18n.language, { weekday: "short" });
  const weekdays = weekDays(month).map((d) => weekday.format(d));

  return (
    <Page
      title={offset === 0 ? t("nav.month") : relativePeriod(offset, "month", i18n.language)}
      subtitle={title}
      accessory={<PeriodNav offset={offset} onChange={setOffset} currentLabel={t("period.thisMonth")} />}
    >
      <p className="period-total">
        <Duration ms={totalMs} />
      </p>
      <MonthCalendar days={perDay} weekdays={weekdays} todayKey={todayKey} now={now} onOpenDay={openDay} />
      <ActivitySummary
        totals={totals}
        scheduleMs={includeSchedule ? 0 : scheduleMs}
        scheduleName={group?.name}
        scheduleColor={group?.color}
      />
    </Page>
  );
}
