import { useEffect, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import type { TFunction } from "i18next";
import { commands, events, type SignInOutcome, type SyncError, type SyncStatus } from "../../lib/bindings";
import { dateKey, formatClock } from "../../lib/time";

/** Live sync status: read once, then follow Rust's SyncStatusChanged event. */
function useSyncStatus(): SyncStatus | undefined {
  const [status, setStatus] = useState<SyncStatus>();
  useEffect(() => {
    let cancelled = false;
    void commands.syncStatus().then((s) => {
      if (!cancelled) setStatus(s);
    });
    const unlisten = events.syncStatusChanged.listen((e) => setStatus(e.payload));
    return () => {
      cancelled = true;
      void unlisten.then((f) => f());
    };
  }, []);
  return status;
}

function errorText(err: SyncError, t: TFunction): string {
  return t(`sync.error.${err.code}`, { message: err.message });
}

function syncedAt(ms: number, locale: string): string {
  const clock = formatClock(ms, locale);
  if (dateKey(new Date(ms)) === dateKey(new Date())) return clock;
  return `${new Intl.DateTimeFormat(locale, { month: "short", day: "numeric" }).format(ms)} ${clock}`;
}

type Note = { kind: "ok" | "error"; text: string } | null;

/**
 * What the signed-out form is asking for (rebuild-plan 17.5):
 * email + password → the sign-up code → (forgot) the address to send a reset code to → the reset code + new password.
 */
type Mode = "credentials" | "verify" | "forgot" | "reset";

type Result<T> = { status: "ok"; data: T } | { status: "error"; error: SyncError };

/** Settings → Sync (rebuild-plan 12.4, 17). All network work happens in Rust. */
export function SyncSettings() {
  const { t, i18n } = useTranslation();
  const status = useSyncStatus();
  const [mode, setMode] = useState<Mode>("credentials");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<Note>(null);

  // Offer the last account used on this device.
  useEffect(() => {
    if (status?.phase === "signed_out" && status.email) setEmail((current) => current || status.email || "");
  }, [status?.phase, status?.email]);

  if (!status) return null;

  const fail = (error: SyncError) => setNote({ kind: "error", text: errorText(error, t) });

  /** Runs one command, showing its error; `undefined` when it failed. */
  const run = async <T,>(call: () => Promise<Result<T>>): Promise<T | undefined> => {
    setBusy(true);
    setNote(null);
    const res = await call();
    setBusy(false);
    if (res.status === "error") {
      fail(res.error);
      return undefined;
    }
    return res.data;
  };

  const backToCredentials = () => {
    setMode("credentials");
    setCode("");
    setNote(null);
  };

  /**
   * Ends a sign-in. Codes are spent once verified, so after "use a different account?" the account
   * (which can sign in by then) is signed into with its password, `confirmSwitch` set.
   */
  const settle = async (outcome: SignInOutcome, passwordForSwitch: string) => {
    if (outcome.kind === "signed_in") {
      setPassword("");
      setCode("");
      setMode("credentials");
    } else if (outcome.kind === "check_email") {
      setMode("verify");
      setCode("");
      setNote({ kind: "ok", text: t("sync.codeSentTo", { email }) });
    } else {
      const ok = await commands.dialogConfirm(
        t("sync.switchTitle"),
        t("sync.switchBody", { previous: outcome.previous_email ?? t("sync.anotherAccount"), next: email }),
        t("sync.switchConfirm"),
        t("common.cancel"),
      );
      if (!ok) return;
      const next = await run(() => commands.syncSignIn(email, passwordForSwitch, true));
      if (next) await settle(next, passwordForSwitch);
    }
  };

  const signIn = async () => {
    setBusy(true);
    setNote(null);
    const res = await commands.syncSignIn(email, password, false);
    setBusy(false);
    if (res.status === "error") {
      fail(res.error);
      // Sign-up was never finished: the code can still be entered (or sent again).
      if (res.error.code === "email_not_confirmed") setMode("verify");
      return;
    }
    await settle(res.data, password);
  };

  const signUp = async () => {
    const outcome = await run(() => commands.syncSignUp(email, password, false));
    if (outcome) await settle(outcome, password);
  };

  const verify = async () => {
    const outcome = await run(() => commands.syncVerifySignUp(email, code, false));
    if (outcome) await settle(outcome, password);
  };

  const sendResetCode = async () => {
    const ok = await run(() => commands.syncRequestPasswordReset(email));
    if (ok !== undefined) {
      setMode("reset");
      setCode("");
      setPassword("");
      setNote({ kind: "ok", text: t("sync.resetSentTo", { email }) });
    }
  };

  const resend = async () => {
    const ok = await run(() =>
      mode === "reset" ? commands.syncRequestPasswordReset(email) : commands.syncResendSignUpCode(email),
    );
    if (ok !== undefined) setNote({ kind: "ok", text: t("sync.codeResent", { email }) });
  };

  const resetPassword = async () => {
    const outcome = await run(() => commands.syncResetPassword(email, code, password, false));
    if (outcome) await settle(outcome, password);
  };

  const signOut = async () => {
    const ok = await run(() => commands.syncSignOut());
    if (ok !== undefined) setNote({ kind: "ok", text: t("sync.signedOutNote") });
  };

  const deleteAccount = async () => {
    const ok = await commands.dialogConfirm(
      t("sync.deleteTitle"),
      t("sync.deleteBody", { email: status.email ?? "" }),
      t("sync.deleteConfirm"),
      t("common.cancel"),
    );
    if (!ok) return;
    const done = await run(() => commands.syncDeleteAccount());
    if (done !== undefined) {
      setEmail("");
      setNote({ kind: "ok", text: t("sync.deletedNote") });
    }
  };

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    switch (mode) {
      case "credentials":
        if (canSubmitCredentials) void signIn();
        break;
      case "verify":
        if (canSubmitCode) void verify();
        break;
      case "forgot":
        if (hasEmail) void sendResetCode();
        break;
      case "reset":
        if (canSubmitCode && password) void resetPassword();
        break;
    }
  };

  const statusText = (() => {
    switch (status.phase) {
      case "not_configured":
        return t("sync.notConfigured");
      case "signed_out":
        return t("sync.signedOut");
      case "syncing":
        return t("sync.syncing");
      case "synced":
        return status.last_ok_ms === null ? t("sync.syncing") : t("sync.synced", { time: syncedAt(status.last_ok_ms, i18n.language) });
      case "error":
        return t("sync.failed");
    }
  })();

  const signedIn = status.phase === "syncing" || status.phase === "synced" || status.phase === "error";
  const hasEmail = !busy && email.trim() !== "";
  const canSubmitCredentials = hasEmail && password !== "";
  const canSubmitCode = hasEmail && code.trim().length === 6;
  // A background failure (or an expired session) is shown under the group unless a fresher note replaces it.
  const footnote: Note =
    note ??
    (status.error && status.phase !== "not_configured" ? { kind: "error", text: errorText(status.error, t) } : null);

  const emailRow = (
    <label className="settings-row">
      <span>{t("sync.email")}</span>
      <input
        className="settings-input"
        type="email"
        autoComplete="username"
        spellCheck={false}
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />
    </label>
  );

  const passwordRow = (label: string, autoComplete: "current-password" | "new-password") => (
    <label className="settings-row">
      <span>{label}</span>
      <input
        className="settings-input"
        type="password"
        autoComplete={autoComplete}
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />
    </label>
  );

  const codeRow = (
    <label className="settings-row">
      <span>{t("sync.code")}</span>
      <input
        className="settings-input"
        type="text"
        inputMode="numeric"
        autoComplete="one-time-code"
        maxLength={6}
        spellCheck={false}
        value={code}
        onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
      />
    </label>
  );

  const backButton = (
    <button type="button" className="settings-button" disabled={busy} onClick={backToCredentials}>
      {t("sync.back")}
    </button>
  );

  const resendButton = (
    <button type="button" className="settings-button" disabled={!hasEmail} onClick={() => void resend()}>
      {t("sync.resendCode")}
    </button>
  );

  const form = (() => {
    switch (mode) {
      case "credentials":
        return (
          <>
            {emailRow}
            {passwordRow(t("sync.password"), "current-password")}
            <div className="settings-row">
              <span>{t("sync.signedOutHint")}</span>
              <span className="settings-inline">
                <button type="button" className="settings-button" disabled={!canSubmitCredentials} onClick={() => void signUp()}>
                  {t("sync.signUp")}
                </button>
                <button type="submit" className="settings-button is-primary" disabled={!canSubmitCredentials}>
                  {t("sync.signIn")}
                </button>
              </span>
            </div>
            <div className="settings-row">
              <span />
              <button type="button" className="settings-button" disabled={busy} onClick={() => setMode("forgot")}>
                {t("sync.forgotPassword")}
              </button>
            </div>
          </>
        );
      case "verify":
        return (
          <>
            {codeRow}
            <div className="settings-row">
              <span>{t("sync.enterCodeHint")}</span>
              <span className="settings-inline">
                {backButton}
                {resendButton}
                <button type="submit" className="settings-button is-primary" disabled={!canSubmitCode}>
                  {t("sync.confirmCode")}
                </button>
              </span>
            </div>
          </>
        );
      case "forgot":
        return (
          <>
            {emailRow}
            <div className="settings-row">
              <span>{t("sync.resetHint")}</span>
              <span className="settings-inline">
                {backButton}
                <button type="submit" className="settings-button is-primary" disabled={!hasEmail}>
                  {t("sync.sendCode")}
                </button>
              </span>
            </div>
          </>
        );
      case "reset":
        return (
          <>
            {codeRow}
            {passwordRow(t("sync.newPassword"), "new-password")}
            <div className="settings-row">
              <span>{t("sync.passwordHint")}</span>
              <span className="settings-inline">
                {backButton}
                {resendButton}
                <button type="submit" className="settings-button is-primary" disabled={!canSubmitCode || !password}>
                  {t("sync.resetPassword")}
                </button>
              </span>
            </div>
          </>
        );
    }
  })();

  return (
    <section className="settings-group">
      <h2 className="settings-group-title">{t("sync.title")}</h2>
      <div className="settings-rows">
        <div className="settings-row">
          <span>{t("sync.status")}</span>
          <span className="settings-value-text">{statusText}</span>
        </div>

        {signedIn && (
          <>
            <div className="settings-row">
              <span>{t("sync.account")}</span>
              <span className="settings-value-text settings-path">{status.email ?? ""}</span>
            </div>
            <div className="settings-row">
              <span>{t("sync.signedInHint")}</span>
              <span className="settings-inline">
                <button type="button" className="settings-button" disabled={busy} onClick={() => void commands.syncNow()}>
                  {t("sync.syncNow")}
                </button>
                <button type="button" className="settings-button" disabled={busy} onClick={() => void signOut()}>
                  {t("sync.signOut")}
                </button>
              </span>
            </div>
            <div className="settings-row">
              <span>{t("sync.deleteHint")}</span>
              <button type="button" className="settings-button is-destructive" disabled={busy} onClick={() => void deleteAccount()}>
                {t("sync.deleteAccount")}
              </button>
            </div>
          </>
        )}

        {status.phase === "signed_out" && (
          <form className="settings-form" onSubmit={onSubmit}>
            {form}
          </form>
        )}
      </div>
      {status.phase === "not_configured" && <p className="settings-footnote">{t("sync.notConfiguredHint")}</p>}
      {footnote && <p className={footnote.kind === "error" ? "settings-footnote is-error" : "settings-footnote"}>{footnote.text}</p>}
    </section>
  );
}
