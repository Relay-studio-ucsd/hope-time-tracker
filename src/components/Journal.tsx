import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { commands } from "../lib/bindings";
import { run, useQuery } from "../lib/data";
import "./Journal.css";

const SAVE_DELAY = 800;

/** One entry per day; saves shortly after typing stops and when focus leaves. */
/** The day's journal; `past` only changes the heading, since "today's" would be wrong for an earlier day. */
export function Journal({ date, past = false }: { date: string; past?: boolean }) {
  const { t } = useTranslation();
  const entries = useQuery(() => commands.journalList({ from: date, to: date }), [date]);
  const stored = entries?.[0]?.text ?? "";
  const [text, setText] = useState(stored);
  const dirty = useRef(false);
  const timer = useRef<number>();

  // Adopt stored text unless the user is mid-edit (e.g. a refetch after our own save).
  useEffect(() => {
    if (!dirty.current) setText(stored);
  }, [stored]);

  const save = (value: string) => {
    window.clearTimeout(timer.current);
    dirty.current = false;
    if (value !== stored) void run(commands.journalUpsert(date, value));
  };

  return (
    <section className="journal">
      <h2 className="journal-title">{t(past ? "journal.titlePast" : "journal.title")}</h2>
      <textarea
        className="journal-text"
        value={text}
        placeholder={t("journal.placeholder")}
        rows={4}
        onChange={(e) => {
          const value = e.target.value;
          setText(value);
          dirty.current = true;
          window.clearTimeout(timer.current);
          timer.current = window.setTimeout(() => save(value), SAVE_DELAY);
        }}
        onBlur={(e) => save(e.target.value)}
      />
    </section>
  );
}
