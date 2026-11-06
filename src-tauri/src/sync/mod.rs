//! Stage 7: sync with Supabase (rebuild-plan 12).
//!
//! - `tables`  how rows move between SQLite and JSON, and the last-write-wins merge
//! - `engine`  push / pull against any `Remote`
//! - `http`    GoTrue + PostgREST over reqwest
//! - here      sign-in state, the refresh token in the OS keychain, and the background schedule
//!
//! Without a build-time Supabase config nothing here runs and the app is local-only.

pub mod engine;
mod error;
mod http;
pub mod tables;

#[cfg(test)]
mod fake;
#[cfg(test)]
mod tests;

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use specta::Type;
use tauri::{AppHandle, Manager};
use tauri_specta::Event;

pub use error::{SyncError, SyncErrorCode};
use http::{CodeKind, Config, HttpRemote, SignUp, TokenSource, Tokens};

use crate::db::{now_ms, setting, Db};
use crate::events;

/// Local settings (rebuild-plan 12.2). `sync.email` is extra: it labels the account in Settings and in
/// the "different account" confirmation.
const USER_ID: &str = "sync.user_id";
const EMAIL: &str = "sync.email";
const LAST_OK: &str = "sync.last_ok_ms";
const LAST_ERROR: &str = "sync.last_error";

const PULL_EVERY: Duration = Duration::from_secs(5);
const PUSH_DEBOUNCE: Duration = Duration::from_millis(500);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// Refresh the access token this long before it expires.
const TOKEN_MARGIN_MS: i64 = 60_000;
/// `sync.last_ok_ms` is written at most this often (the in-memory value is always current).
const LAST_OK_SAVE_MS: i64 = 30_000;
/// Shortest password accepted when creating an account or resetting one (rebuild-plan 17.3); the
/// project's own setting is the authority, this only saves a round trip.
const MIN_PASSWORD_CHARS: usize = 8;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "snake_case")]
pub enum SyncPhase {
    /// This build has no Supabase project.
    NotConfigured,
    SignedOut,
    /// Signed in, first round since start / sign-in not finished yet.
    Syncing,
    /// Up to date as of `last_ok_ms`.
    Synced,
    /// The last round failed; retrying with backoff.
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
pub struct SyncStatus {
    pub phase: SyncPhase,
    /// Signed-in account, or the last one used on this device when signed out.
    pub email: Option<String>,
    #[specta(type = Option<specta_typescript::Number>)]
    pub last_ok_ms: Option<i64>,
    pub error: Option<SyncError>,
}

/// Sync status changed; the Settings page re-renders from the payload.
#[derive(Debug, Clone, Serialize, Deserialize, Type, Event)]
pub struct SyncStatusChanged(pub SyncStatus);

#[derive(Debug, Clone, Serialize, Type)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SignInOutcome {
    SignedIn,
    /// This device last synced a different account. Nothing was stored; call again with
    /// `confirm_switch` after asking the user. Local data is then merged into the new account.
    ConfirmSwitch { previous_email: Option<String> },
    /// A 6-digit code was emailed; finish with `verify_sign_up`.
    CheckEmail,
}

/// A password-reset code that was already verified (and so is spent) while the new password has not
/// been accepted yet; lets the user retry with another password (rebuild-plan 17.3).
struct PendingReset {
    email: String,
    code: String,
    tokens: Tokens,
}

struct AuthSession {
    user_id: String,
    email: Option<String>,
    refresh_token: String,
    access_token: Option<String>,
    expires_at_ms: i64,
}

#[derive(Default)]
struct Runtime {
    synced_once: bool,
    error: Option<SyncError>,
    last_ok_ms: Option<i64>,
    last_ok_saved_ms: i64,
    last_emitted: Option<SyncStatus>,
}

enum Msg {
    LocalWrite,
    SyncNow,
}

struct Inner {
    app: AppHandle,
    config: Option<Config>,
    client: reqwest::Client,
    auth: Mutex<Option<AuthSession>>,
    pending_reset: Mutex<Option<PendingReset>>,
    runtime: Mutex<Runtime>,
    tx: Mutex<Option<Sender<Msg>>>,
}

/// Managed state. Cheap to clone.
#[derive(Clone)]
pub struct SyncService(Arc<Inner>);

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

mod keychain {
    use super::error::{SyncError, SyncErrorCode};

    const SERVICE: &str = "io.github.dan9574.hope";
    const ACCOUNT: &str = "supabase-refresh-token";

    fn entry() -> Result<keyring::Entry, SyncError> {
        keyring::Entry::new(SERVICE, ACCOUNT).map_err(|e| SyncError::new(SyncErrorCode::Keychain, e.to_string()))
    }

    pub fn load() -> Option<String> {
        entry().ok()?.get_password().ok()
    }

    pub fn save(token: &str) -> Result<(), SyncError> {
        entry()?.set_password(token).map_err(|e| SyncError::new(SyncErrorCode::Keychain, e.to_string()))
    }

    pub fn delete() {
        if let Ok(e) = entry() {
            match e.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => {}
                Err(err) => eprintln!("sync: could not remove the keychain item: {err}"),
            }
        }
    }
}

/// Whether this build was given a Supabase project (rebuild-plan 12.4).
pub fn configured() -> bool {
    Config::from_build().is_some()
}

/// Creates the managed `SyncService` state and, when configured, starts the background thread.
/// Call after `Db` is managed.
pub fn init(app: &AppHandle) -> crate::error::Result<()> {
    let config = Config::from_build();
    let db = app.state::<Db>();
    let (user_id, email, last_ok) = {
        let conn = db.conn();
        (
            setting::get(&conn, USER_ID)?,
            setting::get(&conn, EMAIL)?,
            setting::get(&conn, LAST_OK)?.and_then(|v| v.parse().ok()),
        )
    };
    // Only touch the keychain when this device has signed in before.
    let auth = match (&config, user_id) {
        (Some(_), Some(user_id)) => keychain::load().map(|refresh_token| AuthSession {
            user_id,
            email,
            refresh_token,
            access_token: None,
            expires_at_ms: 0,
        }),
        _ => None,
    };
    // `sync.last_error` is kept for diagnosis only; a fresh start retries before showing any error.
    let runtime = Runtime { last_ok_ms: last_ok, last_ok_saved_ms: last_ok.unwrap_or(0), ..Runtime::default() };
    let configured = config.is_some();
    let sync = SyncService(Arc::new(Inner {
        app: app.clone(),
        config,
        client: http::client(),
        auth: Mutex::new(auth),
        pending_reset: Mutex::new(None),
        runtime: Mutex::new(runtime),
        tx: Mutex::new(None),
    }));
    if configured {
        let (tx, rx) = mpsc::channel();
        *lock(&sync.0.tx) = Some(tx);
        let worker = sync.clone();
        std::thread::Builder::new().name("hope-sync".into()).spawn(move || worker.run(rx))?;
    }
    app.manage(sync);
    Ok(())
}

/// A local write happened; push soon. No-op when sync is off.
pub fn notify_local_write(app: &AppHandle) {
    if let Some(sync) = app.try_state::<SyncService>() {
        sync.send(Msg::LocalWrite);
    }
}

fn check_password(password: &str) -> Result<(), SyncError> {
    if password.chars().count() < MIN_PASSWORD_CHARS {
        return Err(SyncError::new(SyncErrorCode::WeakPassword, format!("shorter than {MIN_PASSWORD_CHARS} characters")));
    }
    Ok(())
}

fn backoff(failures: u32) -> Duration {
    let secs = PULL_EVERY.as_secs().saturating_mul(1 << failures.saturating_sub(1).min(5));
    Duration::from_secs(secs).min(MAX_BACKOFF)
}

impl SyncService {
    fn config(&self) -> Result<&Config, SyncError> {
        self.0.config.as_ref().ok_or_else(|| SyncError::new(SyncErrorCode::NotConfigured, "no Supabase config in this build"))
    }

    fn send(&self, msg: Msg) {
        if let Some(tx) = lock(&self.0.tx).as_ref() {
            let _ = tx.send(msg);
        }
    }

    fn signed_in(&self) -> bool {
        lock(&self.0.auth).is_some()
    }

    pub fn status(&self) -> SyncStatus {
        let rt = lock(&self.0.runtime);
        let auth = lock(&self.0.auth);
        let (phase, email) = if self.0.config.is_none() {
            (SyncPhase::NotConfigured, None)
        } else if let Some(a) = auth.as_ref() {
            let phase = if rt.error.is_some() {
                SyncPhase::Error
            } else if rt.synced_once {
                SyncPhase::Synced
            } else {
                SyncPhase::Syncing
            };
            (phase, a.email.clone())
        } else {
            let email = setting::get(&self.0.app.state::<Db>().conn(), EMAIL).ok().flatten();
            (SyncPhase::SignedOut, email)
        };
        SyncStatus { phase, email, last_ok_ms: rt.last_ok_ms, error: rt.error.clone() }
    }

    fn emit_status(&self) {
        let status = self.status();
        let mut rt = lock(&self.0.runtime);
        if rt.last_emitted.as_ref() == Some(&status) {
            return;
        }
        rt.last_emitted = Some(status.clone());
        drop(rt);
        if let Err(e) = SyncStatusChanged(status).emit(&self.0.app) {
            eprintln!("failed to emit SyncStatusChanged: {e}");
        }
    }

    // --- Sign-in ---------------------------------------------------------------------------

    pub async fn sign_in(&self, email: &str, password: &str, confirm_switch: bool) -> Result<SignInOutcome, SyncError> {
        let tokens = http::sign_in(&self.0.client, self.config()?, email.trim(), password).await?;
        self.establish(tokens, confirm_switch)
    }

    pub async fn sign_up(&self, email: &str, password: &str, confirm_switch: bool) -> Result<SignInOutcome, SyncError> {
        let cfg = self.config()?;
        check_password(password)?;
        match http::sign_up(&self.0.client, cfg, email.trim(), password).await? {
            SignUp::SignedIn(tokens) => self.establish(tokens, confirm_switch),
            SignUp::ConfirmEmail => Ok(SignInOutcome::CheckEmail),
        }
    }

    /// Finishes a sign-up with the emailed code. The code is spent by a correct answer, so after
    /// `ConfirmSwitch` the caller continues with a plain `sign_in` (the account can sign in by then).
    pub async fn verify_sign_up(&self, email: &str, code: &str, confirm_switch: bool) -> Result<SignInOutcome, SyncError> {
        let tokens = http::verify_code(&self.0.client, self.config()?, CodeKind::SignUp, email.trim(), code.trim()).await?;
        self.establish(tokens, confirm_switch)
    }

    pub async fn resend_sign_up_code(&self, email: &str) -> Result<(), SyncError> {
        http::resend_sign_up_code(&self.0.client, self.config()?, email.trim()).await
    }

    /// Emails a password-reset code. Succeeds whether or not the address has an account.
    pub async fn request_password_reset(&self, email: &str) -> Result<(), SyncError> {
        http::recover(&self.0.client, self.config()?, email.trim()).await
    }

    /// Verifies the reset code, sets the new password and signs in. After `ConfirmSwitch` the caller
    /// continues with a plain `sign_in` using the new password.
    pub async fn reset_password(
        &self,
        email: &str,
        code: &str,
        new_password: &str,
        confirm_switch: bool,
    ) -> Result<SignInOutcome, SyncError> {
        let cfg = self.config()?;
        let (email, code) = (email.trim(), code.trim());
        check_password(new_password)?;
        // A code verifies only once: reuse the session from an earlier attempt with the same code.
        let earlier = lock(&self.0.pending_reset).take().filter(|p| p.email == email && p.code == code);
        let tokens = match earlier {
            Some(p) => p.tokens,
            None => http::verify_code(&self.0.client, cfg, CodeKind::Recovery, email, code).await?,
        };
        if let Err(e) = http::update_password(&self.0.client, cfg, &tokens.access_token, new_password).await {
            *lock(&self.0.pending_reset) = Some(PendingReset { email: email.to_owned(), code: code.to_owned(), tokens });
            return Err(e);
        }
        self.establish(tokens, confirm_switch)
    }

    /// Deletes the signed-in account and everything it stored in the cloud (rebuild-plan 17.4).
    /// Records on this device stay, and the device forgets the account entirely: the next sign-in,
    /// to any account, uploads them again without asking about a switch.
    pub async fn delete_account(&self) -> Result<(), SyncError> {
        let cfg = self.config()?;
        let mut force = false;
        loop {
            // `access_token` blocks on the refresh request, so it must not run on a runtime thread.
            let source = self.clone();
            let token = tauri::async_runtime::spawn_blocking(move || source.access_token(force))
                .await
                .map_err(|e| SyncError::new(SyncErrorCode::Server, e.to_string()))??;
            match http::delete_account(&self.0.client, cfg, &token).await {
                Err(e) if e.code == SyncErrorCode::SessionExpired && !force => force = true,
                other => break other?,
            }
        }
        lock(&self.0.auth).take();
        keychain::delete();
        {
            let db = self.0.app.state::<Db>();
            let conn = db.conn();
            for key in [USER_ID, EMAIL, LAST_OK, LAST_ERROR] {
                setting::remove(&conn, key)?;
            }
        }
        {
            let mut rt = lock(&self.0.runtime);
            rt.error = None;
            rt.synced_once = false;
            rt.last_ok_ms = None;
            rt.last_ok_saved_ms = 0;
        }
        self.emit_status();
        Ok(())
    }

    fn establish(&self, tokens: Tokens, confirm_switch: bool) -> Result<SignInOutcome, SyncError> {
        let user_id = tokens.user.id.clone();
        let db = self.0.app.state::<Db>();
        let previous = setting::get(&db.conn(), USER_ID)?;
        if previous.as_ref().is_some_and(|p| *p != user_id) && !confirm_switch {
            let previous_email = setting::get(&db.conn(), EMAIL)?;
            return Ok(SignInOutcome::ConfirmSwitch { previous_email });
        }
        keychain::save(&tokens.refresh_token)?;
        {
            let mut conn = db.conn();
            let tx = conn.transaction()?;
            if previous.as_deref() != Some(user_id.as_str()) {
                // First sign-in here, or another account: offer every local row to it and pull from scratch.
                tables::reset_for_new_account(&tx)?;
            }
            setting::set(&tx, USER_ID, &user_id)?;
            match &tokens.user.email {
                Some(email) => setting::set(&tx, EMAIL, email)?,
                None => setting::remove(&tx, EMAIL)?,
            }
            setting::remove(&tx, LAST_ERROR)?;
            tx.commit()?;
        }
        *lock(&self.0.auth) = Some(AuthSession {
            user_id,
            email: tokens.user.email.clone(),
            refresh_token: tokens.refresh_token,
            access_token: Some(tokens.access_token),
            expires_at_ms: now_ms() + tokens.expires_in * 1000,
        });
        {
            let mut rt = lock(&self.0.runtime);
            rt.error = None;
            rt.synced_once = false;
        }
        self.emit_status();
        self.send(Msg::SyncNow);
        Ok(SignInOutcome::SignedIn)
    }

    /// Signs out on this device. Local data stays; the account is remembered to detect a switch later.
    pub async fn sign_out(&self) -> Result<(), SyncError> {
        let session = lock(&self.0.auth).take();
        keychain::delete();
        {
            let mut rt = lock(&self.0.runtime);
            rt.error = None;
        }
        let _ = setting::remove(&self.0.app.state::<Db>().conn(), LAST_ERROR);
        self.emit_status();
        if let (Some(token), Ok(cfg)) = (session.and_then(|s| s.access_token), self.config()) {
            http::sign_out(&self.0.client, cfg, &token).await;
        }
        Ok(())
    }

    pub fn sync_now(&self) {
        self.send(Msg::SyncNow);
    }

    /// The refresh token was rejected: drop the session so the user signs in again.
    fn session_expired(&self, error: SyncError) {
        lock(&self.0.auth).take();
        keychain::delete();
        lock(&self.0.runtime).error = Some(error);
        self.emit_status();
    }

    // --- Background schedule (rebuild-plan 12.3) ---------------------------------------------

    fn run(self, rx: Receiver<Msg>) {
        let mut next_full = Some(Instant::now()); // full round at start
        let mut push_at: Option<Instant> = None;
        let mut failures: u32 = 0;
        loop {
            let deadline = [next_full, push_at].into_iter().flatten().min();
            let msg = match deadline {
                Some(t) => rx.recv_timeout(t.saturating_duration_since(Instant::now())),
                None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match msg {
                Ok(Msg::LocalWrite) => {
                    // While backing off, the retry will carry the change.
                    if failures == 0 && self.signed_in() {
                        push_at = Some(Instant::now() + PUSH_DEBOUNCE);
                    }
                    continue;
                }
                Ok(Msg::SyncNow) => {
                    next_full = Some(Instant::now());
                    failures = 0;
                    continue;
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            if !self.signed_in() {
                // Sleep until sign-in sends SyncNow.
                next_full = None;
                push_at = None;
                failures = 0;
                continue;
            }
            let now = Instant::now();
            let full = next_full.is_some_and(|t| t <= now);
            push_at = None;
            let result = self.round(full);
            match result {
                Ok(()) => {
                    failures = 0;
                    if full {
                        next_full = Some(Instant::now() + PULL_EVERY);
                    }
                }
                Err(e) if e.code == SyncErrorCode::SignedOut => {}
                Err(e) => {
                    failures += 1;
                    next_full = Some(Instant::now() + backoff(failures));
                    eprintln!("sync: {e} (retrying in {:?})", backoff(failures));
                }
            }
        }
    }

    fn round(&self, full: bool) -> Result<(), SyncError> {
        let db = self.0.app.state::<Db>();
        let cfg = self.config()?;
        let remote = HttpRemote { client: &self.0.client, cfg, tokens: self };
        let result = if full { engine::sync(&db, &remote) } else { engine::push(&db, &remote) };
        match result {
            Ok(changed) => {
                if changed {
                    events::data_changed_by_sync(&self.0.app);
                }
                self.record_ok(&db);
                Ok(())
            }
            Err(e) if e.code == SyncErrorCode::SignedOut => Err(e),
            Err(e) if e.code == SyncErrorCode::SessionExpired => {
                self.session_expired(e.clone());
                Err(SyncError::new(SyncErrorCode::SignedOut, "session expired"))
            }
            // Signed out (or the account was deleted) while the round was in flight: nothing to report.
            Err(_) if !self.signed_in() => Err(SyncError::new(SyncErrorCode::SignedOut, "signed out during the round")),
            Err(e) => {
                let _ = setting::set(&db.conn(), LAST_ERROR, &e.to_string());
                lock(&self.0.runtime).error = Some(e.clone());
                self.emit_status();
                Err(e)
            }
        }
    }

    fn record_ok(&self, db: &Db) {
        let now = now_ms();
        let (save, clear_error) = {
            let mut rt = lock(&self.0.runtime);
            let clear_error = rt.error.take().is_some();
            rt.synced_once = true;
            rt.last_ok_ms = Some(now);
            let save = now - rt.last_ok_saved_ms >= LAST_OK_SAVE_MS;
            if save {
                rt.last_ok_saved_ms = now;
            }
            (save, clear_error)
        };
        if save || clear_error {
            let conn = db.conn();
            let _ = setting::set(&conn, LAST_OK, &now.to_string());
            if clear_error {
                let _ = setting::remove(&conn, LAST_ERROR);
            }
        }
        self.emit_status();
    }
}

impl TokenSource for SyncService {
    fn access_token(&self, force: bool) -> Result<String, SyncError> {
        let (refresh_token, user_id) = {
            let auth = lock(&self.0.auth);
            let a = auth.as_ref().ok_or_else(|| SyncError::new(SyncErrorCode::SignedOut, "not signed in"))?;
            if let (false, Some(token)) = (force, &a.access_token) {
                if a.expires_at_ms - TOKEN_MARGIN_MS > now_ms() {
                    return Ok(token.clone());
                }
            }
            (a.refresh_token.clone(), a.user_id.clone())
        };
        let tokens = tauri::async_runtime::block_on(http::refresh(&self.0.client, self.config()?, &refresh_token))?;
        let mut auth = lock(&self.0.auth);
        match auth.as_mut() {
            Some(a) if a.user_id == user_id => {
                // Refresh tokens rotate: the old one is now spent, so the keychain must get the new one.
                if let Err(e) = keychain::save(&tokens.refresh_token) {
                    eprintln!("sync: could not store the refreshed token: {e}");
                }
                a.refresh_token = tokens.refresh_token;
                a.access_token = Some(tokens.access_token.clone());
                a.expires_at_ms = now_ms() + tokens.expires_in * 1000;
                Ok(tokens.access_token)
            }
            // Signed out (or into another account) while the request was in flight.
            _ => Err(SyncError::new(SyncErrorCode::SignedOut, "signed out during refresh")),
        }
    }
}

#[cfg(test)]
mod schedule_tests {
    use super::*;

    #[test]
    fn backoff_doubles_up_to_a_minute() {
        let secs: Vec<u64> = (1..=7).map(|n| backoff(n).as_secs()).collect();
        assert_eq!(secs, [5, 10, 20, 40, 60, 60, 60]);
    }
}
