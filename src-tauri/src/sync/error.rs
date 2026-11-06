use std::fmt;

use serde::{Deserialize, Serialize};
use specta::Type;

/// Stable reason the Settings page turns into a localized message (`sync.error.<code>`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "snake_case")]
pub enum SyncErrorCode {
    NotConfigured,
    SignedOut,
    /// No connection, DNS failure, timeout, TLS failure.
    Network,
    InvalidCredentials,
    EmailNotConfirmed,
    UserAlreadyExists,
    WeakPassword,
    /// The emailed 6-digit code is wrong or has expired.
    InvalidCode,
    RateLimited,
    /// The refresh token was rejected; the user has to sign in again.
    SessionExpired,
    /// The server answered with an unexpected error.
    Server,
    Keychain,
    Database,
    /// The server sent something we could not read.
    Decode,
}

/// Error from the sync layer; also what the sync commands return to the page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
pub struct SyncError {
    pub code: SyncErrorCode,
    /// Developer-facing detail.
    pub message: String,
}

impl SyncError {
    pub fn new(code: SyncErrorCode, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    pub fn decode(message: impl Into<String>) -> Self {
        Self::new(SyncErrorCode::Decode, message)
    }

    pub fn network(e: impl fmt::Display) -> Self {
        Self::new(SyncErrorCode::Network, e.to_string())
    }
}

impl fmt::Display for SyncError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}

impl std::error::Error for SyncError {}

impl From<rusqlite::Error> for SyncError {
    fn from(e: rusqlite::Error) -> Self {
        Self::new(SyncErrorCode::Database, e.to_string())
    }
}

impl From<crate::error::Error> for SyncError {
    fn from(e: crate::error::Error) -> Self {
        Self::new(SyncErrorCode::Database, e.to_string())
    }
}
