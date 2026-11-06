//! Supabase over HTTPS: GoTrue for auth, PostgREST for the tables (rebuild-plan 12.3 / 12.4).
//! The page never talks to Supabase; everything goes through here.

use std::time::Duration;

use reqwest::{Client, RequestBuilder, StatusCode};
use serde::Deserialize;
use serde_json::{json, Value as Json};

use super::engine::Remote;
use super::error::{SyncError, SyncErrorCode};
use super::tables::{Row, Table};

/// Project settings baked in at build time from the root `.env` (see `build.rs`).
pub struct Config {
    pub url: String,
    pub anon_key: String,
}

impl Config {
    pub fn from_build() -> Option<Self> {
        let url = option_env!("HOPE_SUPABASE_URL")?.trim().trim_end_matches('/');
        let anon_key = option_env!("HOPE_SUPABASE_ANON_KEY")?.trim();
        if url.is_empty() || anon_key.is_empty() {
            return None;
        }
        Some(Self { url: url.to_owned(), anon_key: anon_key.to_owned() })
    }
}

pub fn client() -> Client {
    Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .build()
        .expect("HTTP client")
}

// ---------------------------------------------------------------------------------------------
// GoTrue

#[derive(Debug, Clone, Deserialize)]
pub struct User {
    pub id: String,
    #[serde(default)]
    pub email: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tokens {
    pub access_token: String,
    pub refresh_token: String,
    /// Seconds.
    pub expires_in: i64,
    pub user: User,
}

#[derive(Debug)]
pub enum SignUp {
    SignedIn(Tokens),
    /// The project requires email confirmation; no session until the emailed code is verified.
    ConfirmEmail,
}

/// Which emailed code `verify_code` checks (rebuild-plan 17.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodeKind {
    SignUp,
    Recovery,
}

impl CodeKind {
    fn as_str(self) -> &'static str {
        match self {
            CodeKind::SignUp => "signup",
            CodeKind::Recovery => "recovery",
        }
    }
}

async fn send(req: RequestBuilder) -> Result<(StatusCode, String), SyncError> {
    let resp = req.send().await.map_err(SyncError::network)?;
    let status = resp.status();
    let text = resp.text().await.map_err(SyncError::network)?;
    Ok((status, text))
}

fn auth_request(client: &Client, cfg: &Config, path: &str) -> RequestBuilder {
    client.post(format!("{}/auth/v1/{path}", cfg.url)).header("apikey", &cfg.anon_key)
}

/// GoTrue has answered errors in two shapes over the years:
/// `{"error_code": "...", "msg": "..."}` and `{"error": "...", "error_description": "..."}`.
fn auth_error(status: StatusCode, body: &str, refreshing: bool) -> SyncError {
    let parsed: Json = serde_json::from_str(body).unwrap_or(Json::Null);
    let field = |k: &str| parsed.get(k).and_then(Json::as_str).unwrap_or("").to_owned();
    let code = if field("error_code").is_empty() { field("error") } else { field("error_code") };
    let message = [field("msg"), field("error_description"), field("message")]
        .into_iter()
        .find(|m| !m.is_empty())
        .unwrap_or_else(|| format!("HTTP {status}"));
    let kind = if status == StatusCode::TOO_MANY_REQUESTS || code.starts_with("over_") {
        SyncErrorCode::RateLimited
    } else if refreshing && status.is_client_error() {
        SyncErrorCode::SessionExpired
    } else {
        match code.as_str() {
            "invalid_credentials" | "invalid_grant" => SyncErrorCode::InvalidCredentials,
            "email_not_confirmed" => SyncErrorCode::EmailNotConfirmed,
            "user_already_exists" | "email_exists" => SyncErrorCode::UserAlreadyExists,
            "weak_password" => SyncErrorCode::WeakPassword,
            "otp_expired" => SyncErrorCode::InvalidCode,
            _ => SyncErrorCode::Server,
        }
    };
    SyncError::new(kind, format!("{code}: {message}"))
}

fn parse_tokens(body: &str) -> Result<Tokens, SyncError> {
    serde_json::from_str(body).map_err(|e| SyncError::decode(format!("token response: {e}")))
}

pub async fn sign_in(client: &Client, cfg: &Config, email: &str, password: &str) -> Result<Tokens, SyncError> {
    let req = auth_request(client, cfg, "token?grant_type=password").json(&json!({ "email": email, "password": password }));
    let (status, body) = send(req).await?;
    if !status.is_success() {
        return Err(auth_error(status, &body, false));
    }
    parse_tokens(&body)
}

pub async fn sign_up(client: &Client, cfg: &Config, email: &str, password: &str) -> Result<SignUp, SyncError> {
    let req = auth_request(client, cfg, "signup").json(&json!({ "email": email, "password": password }));
    let (status, body) = send(req).await?;
    if !status.is_success() {
        return Err(auth_error(status, &body, false));
    }
    parse_sign_up(&body)
}

fn parse_sign_up(body: &str) -> Result<SignUp, SyncError> {
    let parsed: Json = serde_json::from_str(body).map_err(|e| SyncError::decode(format!("sign-up response: {e}")))?;
    if parsed.get("access_token").is_some() {
        return Ok(SignUp::SignedIn(parse_tokens(body)?));
    }
    // With "Confirm email" on, the answer is the new user without a session. For an address that is
    // already registered GoTrue answers 200 with a made-up user (so addresses cannot be probed) and
    // sends nothing; the one tell is an empty `identities` list.
    if parsed.get("identities").and_then(Json::as_array).is_some_and(Vec::is_empty) {
        return Err(SyncError::new(SyncErrorCode::UserAlreadyExists, "sign-up answered with no identities"));
    }
    Ok(SignUp::ConfirmEmail)
}

/// Checks an emailed 6-digit code. A correct one is spent and answers with a session.
pub async fn verify_code(client: &Client, cfg: &Config, kind: CodeKind, email: &str, code: &str) -> Result<Tokens, SyncError> {
    let req = auth_request(client, cfg, "verify").json(&json!({ "type": kind.as_str(), "email": email, "token": code }));
    let (status, body) = send(req).await?;
    if !status.is_success() {
        return Err(auth_error(status, &body, false));
    }
    parse_tokens(&body)
}

/// Sends the sign-up code again.
pub async fn resend_sign_up_code(client: &Client, cfg: &Config, email: &str) -> Result<(), SyncError> {
    let req = auth_request(client, cfg, "resend").json(&json!({ "type": CodeKind::SignUp.as_str(), "email": email }));
    let (status, body) = send(req).await?;
    if !status.is_success() {
        return Err(auth_error(status, &body, false));
    }
    Ok(())
}

/// Emails a password-reset code. Succeeds whether or not the address has an account.
pub async fn recover(client: &Client, cfg: &Config, email: &str) -> Result<(), SyncError> {
    let req = auth_request(client, cfg, "recover").json(&json!({ "email": email }));
    let (status, body) = send(req).await?;
    if !status.is_success() {
        return Err(auth_error(status, &body, false));
    }
    Ok(())
}

/// Sets a new password for the session behind `access_token`.
pub async fn update_password(client: &Client, cfg: &Config, access_token: &str, password: &str) -> Result<(), SyncError> {
    let req = client
        .put(format!("{}/auth/v1/user", cfg.url))
        .header("apikey", &cfg.anon_key)
        .bearer_auth(access_token)
        .json(&json!({ "password": password }));
    let (status, body) = send(req).await?;
    if !status.is_success() {
        return Err(auth_error(status, &body, false));
    }
    Ok(())
}

/// Deletes the account behind `access_token` and all of its rows (`delete_account()` in
/// `supabase/schema.sql`). A 401 comes back as `SessionExpired` so the caller can refresh and retry.
pub async fn delete_account(client: &Client, cfg: &Config, access_token: &str) -> Result<(), SyncError> {
    let req = client
        .post(format!("{}/rest/v1/rpc/delete_account", cfg.url))
        .header("apikey", &cfg.anon_key)
        .bearer_auth(access_token)
        .json(&json!({}));
    let (status, body) = send(req).await?;
    if status == StatusCode::UNAUTHORIZED {
        return Err(SyncError::new(SyncErrorCode::SessionExpired, "access token rejected"));
    }
    if !status.is_success() {
        let snippet: String = body.chars().take(300).collect();
        return Err(SyncError::new(SyncErrorCode::Server, format!("HTTP {status}: {snippet}")));
    }
    Ok(())
}

pub async fn refresh(client: &Client, cfg: &Config, refresh_token: &str) -> Result<Tokens, SyncError> {
    let req = auth_request(client, cfg, "token?grant_type=refresh_token").json(&json!({ "refresh_token": refresh_token }));
    let (status, body) = send(req).await?;
    if !status.is_success() {
        return Err(auth_error(status, &body, true));
    }
    parse_tokens(&body)
}

/// Ends this device's session on the server. Best effort: signing out locally never depends on it.
pub async fn sign_out(client: &Client, cfg: &Config, access_token: &str) {
    let req = auth_request(client, cfg, "logout?scope=local").bearer_auth(access_token);
    if let Err(e) = send(req).await {
        eprintln!("sync: sign-out request failed: {e}");
    }
}

// ---------------------------------------------------------------------------------------------
// PostgREST

/// Hands out a valid access token, refreshing it when it is about to expire or when `force` is set.
pub trait TokenSource {
    fn access_token(&self, force: bool) -> Result<String, SyncError>;
}

/// Blocking adapter over reqwest for the sync thread, which is not a runtime thread:
/// each call runs on Tauri's tokio runtime through `block_on`.
pub struct HttpRemote<'a> {
    pub client: &'a Client,
    pub cfg: &'a Config,
    pub tokens: &'a dyn TokenSource,
}

impl HttpRemote<'_> {
    fn call(&self, build: impl Fn(&str) -> RequestBuilder) -> Result<Vec<Row>, SyncError> {
        let mut token = self.tokens.access_token(false)?;
        for attempt in 0..2 {
            let req = build(&token).header("apikey", &self.cfg.anon_key).bearer_auth(&token);
            let (status, body) = tauri::async_runtime::block_on(send(req))?;
            if status == StatusCode::UNAUTHORIZED && attempt == 0 {
                // Expired or revoked JWT: refresh once and retry.
                token = self.tokens.access_token(true)?;
                continue;
            }
            if !status.is_success() {
                let snippet: String = body.chars().take(300).collect();
                return Err(SyncError::new(SyncErrorCode::Server, format!("HTTP {status}: {snippet}")));
            }
            return serde_json::from_str(&body).map_err(|e| SyncError::decode(format!("PostgREST response: {e}")));
        }
        Err(SyncError::new(SyncErrorCode::SessionExpired, "access token rejected after refresh"))
    }
}

impl Remote for HttpRemote<'_> {
    fn upsert(&self, table: &Table, rows: &[Row]) -> Result<Vec<Row>, SyncError> {
        let url = format!(
            "{}/rest/v1/{}?on_conflict=user_id,{}&columns={}",
            self.cfg.url,
            table.name,
            table.key,
            table.columns.join(",")
        );
        self.call(|_| {
            self.client
                .post(&url)
                .header("Prefer", "resolution=merge-duplicates,return=representation")
                .json(rows)
        })
    }

    fn fetch(&self, table: &Table, after: i64, limit: usize) -> Result<Vec<Row>, SyncError> {
        let url = format!(
            "{}/rest/v1/{}?select=*&server_seq=gt.{after}&order=server_seq.asc&limit={limit}",
            self.cfg.url, table.name
        );
        self.call(|_| self.client.get(&url))
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{Arc, Mutex};

    use super::*;

    #[derive(Debug, Clone)]
    struct Recorded {
        method: String,
        path: String,
        headers: Vec<(String, String)>,
        body: String,
    }

    impl Recorded {
        fn header(&self, name: &str) -> Option<&str> {
            self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
        }

        fn json(&self) -> Json {
            serde_json::from_str(&self.body).unwrap_or(Json::Null)
        }
    }

    /// A stand-in for GoTrue / PostgREST on a local port (rebuild-plan 17.6): answers each request
    /// from `reply` by method and path, one connection per request, and keeps what it received.
    struct FakeServer {
        url: String,
        requests: Arc<Mutex<Vec<Recorded>>>,
    }

    impl FakeServer {
        fn start(reply: impl Fn(&str, &str) -> (u16, String) + Send + 'static) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let requests = Arc::new(Mutex::new(Vec::new()));
            let log = requests.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { break };
                    let req = read_request(&mut stream);
                    let (status, body) = reply(&req.method, &req.path);
                    log.lock().unwrap().push(req);
                    let head = if status == 204 {
                        format!("HTTP/1.1 {status} No Content\r\nConnection: close\r\n\r\n")
                    } else {
                        format!(
                            "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        )
                    };
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(body.as_bytes());
                }
            });
            Self { url, requests }
        }

        fn config(&self) -> Config {
            Config { url: self.url.clone(), anon_key: "anon".into() }
        }

        fn requests(&self) -> Vec<Recorded> {
            self.requests.lock().unwrap().clone()
        }
    }

    fn read_request(stream: &mut TcpStream) -> Recorded {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 1024];
        let head_end = loop {
            let n = stream.read(&mut chunk).unwrap();
            if n == 0 {
                break buf.len();
            }
            buf.extend_from_slice(&chunk[..n]);
            if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                break i + 4;
            }
        };
        let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
        let mut lines = head.lines();
        let mut first = lines.next().unwrap_or("").split(' ');
        let method = first.next().unwrap_or("").to_owned();
        let path = first.next().unwrap_or("").to_owned();
        let headers: Vec<(String, String)> =
            lines.filter_map(|l| l.split_once(':')).map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned())).collect();
        let len: usize = headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, v)| v.parse().ok())
            .unwrap_or(0);
        let mut body = buf[head_end..].to_vec();
        while body.len() < len {
            let n = stream.read(&mut chunk).unwrap();
            if n == 0 {
                break;
            }
            body.extend_from_slice(&chunk[..n]);
        }
        Recorded { method, path, headers, body: String::from_utf8_lossy(&body).into_owned() }
    }

    #[test]
    fn auth_errors_map_to_codes() {
        let s = StatusCode::BAD_REQUEST;
        assert_eq!(auth_error(s, r#"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#, false).code, SyncErrorCode::InvalidCredentials);
        assert_eq!(auth_error(s, r#"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#, false).code, SyncErrorCode::InvalidCredentials);
        assert_eq!(auth_error(s, r#"{"error_code":"email_not_confirmed","msg":"Email not confirmed"}"#, false).code, SyncErrorCode::EmailNotConfirmed);
        assert_eq!(auth_error(StatusCode::UNPROCESSABLE_ENTITY, r#"{"error_code":"user_already_exists"}"#, false).code, SyncErrorCode::UserAlreadyExists);
        assert_eq!(auth_error(StatusCode::UNPROCESSABLE_ENTITY, r#"{"error_code":"weak_password"}"#, false).code, SyncErrorCode::WeakPassword);
        assert_eq!(auth_error(StatusCode::TOO_MANY_REQUESTS, "", false).code, SyncErrorCode::RateLimited);
        assert_eq!(auth_error(s, r#"{"error_code":"refresh_token_not_found"}"#, true).code, SyncErrorCode::SessionExpired);
        assert_eq!(auth_error(StatusCode::BAD_GATEWAY, "<html>", false).code, SyncErrorCode::Server);
    }

    #[test]
    fn sign_up_answers_are_told_apart() {
        let session = r#"{"access_token":"a","token_type":"bearer","expires_in":3600,"refresh_token":"r","user":{"id":"u","email":"e@x.io"}}"#;
        assert!(matches!(parse_sign_up(session).unwrap(), SignUp::SignedIn(_)));
        let new_user = r#"{"id":"u","email":"e@x.io","identities":[{"id":"u","provider":"email"}]}"#;
        assert!(matches!(parse_sign_up(new_user).unwrap(), SignUp::ConfirmEmail));
        let taken = r#"{"id":"u","email":"e@x.io","identities":[]}"#;
        assert_eq!(parse_sign_up(taken).unwrap_err().code, SyncErrorCode::UserAlreadyExists);
        assert_eq!(parse_sign_up("<html>").unwrap_err().code, SyncErrorCode::Decode);
    }

    #[test]
    fn account_requests_have_the_agreed_shapes() {
        let session = r#"{"access_token":"a","token_type":"bearer","expires_in":3600,"refresh_token":"r","user":{"id":"u","email":"e@x.io"}}"#;
        let server = FakeServer::start(move |method, path| match (method, path) {
            ("POST", "/auth/v1/verify") => (200, session.to_owned()),
            ("POST", "/auth/v1/resend") | ("POST", "/auth/v1/recover") => (200, "{}".to_owned()),
            ("PUT", "/auth/v1/user") => (200, r#"{"id":"u","email":"e@x.io"}"#.to_owned()),
            ("POST", "/rest/v1/rpc/delete_account") => (204, String::new()),
            _ => (404, String::new()),
        });
        let (client, cfg) = (client(), server.config());
        tauri::async_runtime::block_on(async {
            let t = verify_code(&client, &cfg, CodeKind::SignUp, "e@x.io", "123456").await.unwrap();
            assert_eq!((t.access_token.as_str(), t.user.id.as_str()), ("a", "u"));
            verify_code(&client, &cfg, CodeKind::Recovery, "e@x.io", "654321").await.unwrap();
            resend_sign_up_code(&client, &cfg, "e@x.io").await.unwrap();
            recover(&client, &cfg, "e@x.io").await.unwrap();
            update_password(&client, &cfg, "a", "longer-password").await.unwrap();
            delete_account(&client, &cfg, "a").await.unwrap();
        });
        let r = server.requests();
        let lines: Vec<String> = r.iter().map(|r| format!("{} {}", r.method, r.path)).collect();
        assert_eq!(
            lines,
            [
                "POST /auth/v1/verify",
                "POST /auth/v1/verify",
                "POST /auth/v1/resend",
                "POST /auth/v1/recover",
                "PUT /auth/v1/user",
                "POST /rest/v1/rpc/delete_account",
            ]
        );
        assert!(r.iter().all(|r| r.header("apikey") == Some("anon")));
        assert_eq!(r[0].json(), json!({ "type": "signup", "email": "e@x.io", "token": "123456" }));
        assert_eq!(r[1].json(), json!({ "type": "recovery", "email": "e@x.io", "token": "654321" }));
        assert_eq!(r[2].json(), json!({ "type": "signup", "email": "e@x.io" }));
        assert_eq!(r[3].json(), json!({ "email": "e@x.io" }));
        assert_eq!(r[4].json(), json!({ "password": "longer-password" }));
        assert_eq!(r[4].header("authorization"), Some("Bearer a"));
        assert_eq!(r[5].header("authorization"), Some("Bearer a"));
    }

    #[test]
    fn rejected_account_requests_map_to_codes() {
        let server = FakeServer::start(|_, path| match path {
            "/auth/v1/verify" => (403, r#"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#.to_owned()),
            "/auth/v1/user" => (422, r#"{"code":422,"error_code":"weak_password","msg":"Password should be at least 8 characters."}"#.to_owned()),
            "/rest/v1/rpc/delete_account" => (401, r#"{"code":"PGRST301","message":"JWT expired"}"#.to_owned()),
            "/auth/v1/recover" => (429, r#"{"code":429,"error_code":"over_email_send_rate_limit","msg":"For security purposes, you can only request this after 60 seconds."}"#.to_owned()),
            _ => (500, String::new()),
        });
        let (client, cfg) = (client(), server.config());
        tauri::async_runtime::block_on(async {
            let code = |r: Result<(), SyncError>| r.unwrap_err().code;
            assert_eq!(verify_code(&client, &cfg, CodeKind::Recovery, "e@x.io", "000000").await.unwrap_err().code, SyncErrorCode::InvalidCode);
            assert_eq!(code(update_password(&client, &cfg, "a", "short").await), SyncErrorCode::WeakPassword);
            assert_eq!(code(delete_account(&client, &cfg, "a").await), SyncErrorCode::SessionExpired);
            assert_eq!(code(recover(&client, &cfg, "e@x.io").await), SyncErrorCode::RateLimited);
        });
    }

    #[test]
    fn token_response_parses() {
        let t = parse_tokens(
            r#"{"access_token":"a","token_type":"bearer","expires_in":3600,"expires_at":1,"refresh_token":"r","user":{"id":"u","email":"e@x.io","aud":"authenticated"}}"#,
        )
        .unwrap();
        assert_eq!((t.access_token.as_str(), t.refresh_token.as_str(), t.user.id.as_str()), ("a", "r", "u"));
    }
}
