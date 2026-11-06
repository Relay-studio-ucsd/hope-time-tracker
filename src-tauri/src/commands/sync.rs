//! Sync settings (rebuild-plan 12.4). Every network call happens in Rust; the page only sees status.

use tauri::State;

use crate::sync::{SignInOutcome, SyncError, SyncService, SyncStatus};

#[tauri::command]
#[specta::specta]
pub fn sync_status(sync: State<'_, SyncService>) -> SyncStatus {
    sync.status()
}

/// Email + password sign-in. If this device last synced another account the answer is
/// `confirm_switch`; ask the user, then call again with `confirm_switch: true`.
#[tauri::command]
#[specta::specta]
pub async fn sync_sign_in(
    sync: State<'_, SyncService>,
    email: String,
    password: String,
    confirm_switch: bool,
) -> Result<SignInOutcome, SyncError> {
    let sync = sync.inner().clone();
    sync.sign_in(&email, &password, confirm_switch).await
}

/// Creates an account. Answers `check_email` when a 6-digit code was emailed; finish with
/// `sync_verify_sign_up`.
#[tauri::command]
#[specta::specta]
pub async fn sync_sign_up(
    sync: State<'_, SyncService>,
    email: String,
    password: String,
    confirm_switch: bool,
) -> Result<SignInOutcome, SyncError> {
    let sync = sync.inner().clone();
    sync.sign_up(&email, &password, confirm_switch).await
}

/// Finishes creating an account with the emailed code. On `confirm_switch`, ask the user and then
/// call `sync_sign_in` with `confirm_switch: true` (the code is spent, the account can sign in).
#[tauri::command]
#[specta::specta]
pub async fn sync_verify_sign_up(
    sync: State<'_, SyncService>,
    email: String,
    code: String,
    confirm_switch: bool,
) -> Result<SignInOutcome, SyncError> {
    let sync = sync.inner().clone();
    sync.verify_sign_up(&email, &code, confirm_switch).await
}

/// Emails the sign-up code again.
#[tauri::command]
#[specta::specta]
pub async fn sync_resend_sign_up_code(sync: State<'_, SyncService>, email: String) -> Result<(), SyncError> {
    let sync = sync.inner().clone();
    sync.resend_sign_up_code(&email).await
}

/// Emails a password-reset code. Succeeds whether or not the address has an account.
#[tauri::command]
#[specta::specta]
pub async fn sync_request_password_reset(sync: State<'_, SyncService>, email: String) -> Result<(), SyncError> {
    let sync = sync.inner().clone();
    sync.request_password_reset(&email).await
}

/// Sets a new password with the emailed code and signs in. On `confirm_switch`, ask the user and
/// then call `sync_sign_in` with the new password and `confirm_switch: true`.
#[tauri::command]
#[specta::specta]
pub async fn sync_reset_password(
    sync: State<'_, SyncService>,
    email: String,
    code: String,
    new_password: String,
    confirm_switch: bool,
) -> Result<SignInOutcome, SyncError> {
    let sync = sync.inner().clone();
    sync.reset_password(&email, &code, &new_password, confirm_switch).await
}

/// Deletes the signed-in account and all of its cloud data. Local data is kept. The page must
/// confirm with the user first.
#[tauri::command]
#[specta::specta]
pub async fn sync_delete_account(sync: State<'_, SyncService>) -> Result<(), SyncError> {
    let sync = sync.inner().clone();
    sync.delete_account().await
}

/// Signs out on this device. Local data is kept.
#[tauri::command]
#[specta::specta]
pub async fn sync_sign_out(sync: State<'_, SyncService>) -> Result<(), SyncError> {
    let sync = sync.inner().clone();
    sync.sign_out().await
}

/// Push and pull now instead of waiting for the next round.
#[tauri::command]
#[specta::specta]
pub fn sync_now(sync: State<'_, SyncService>) {
    sync.sync_now();
}
