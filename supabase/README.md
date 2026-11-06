# Turning on sync (Supabase)

Hope works fully offline. Sync is switched on at build time by giving the build a Supabase project.
The protocol is described in `docs/rebuild-plan.md`, section 12.

## 1. Create the project

1. Sign in at <https://supabase.com/dashboard> and click **New project**.
2. Pick any name and a region near you, set a database password (you will not need it in Hope), create it.

## 2. Create the tables

1. In the project, open **SQL Editor** → **New query**.
2. Paste the whole of `supabase/schema.sql` and click **Run**. It should finish with "Success. No rows returned".
3. Running it again later is safe.

Check: **Table Editor** now lists `activity`, `day`, `journal`, `plan`, `session`, each marked as having RLS enabled.

## 3. Email sign-in settings

Open **Authentication** → **Sign In / Providers** → **Email** (the menu names move around; it is the Email provider page).

- **Email provider** must be enabled (it is by default).
- **Confirm email**:
  - *On* (default, and required for a public release): "Create Account" in Hope emails a 6-digit code and asks for it.
    This needs the email templates below; with the stock templates the email only carries a link, which Hope cannot use.
  - *Off*: "Create Account" signs you in immediately. Simplest for a personal project.

### Codes instead of links (rebuild-plan 17.2)

Hope has no web page a link could return to, so sign-up and password reset both use the 6-digit code.

1. **Authentication → Emails → Templates**: in **Confirm signup** and **Reset password**, replace the link with the code,
   for example `Your Hope code is {{ .Token }}`. Leave `{{ .ConfirmationURL }}` out.
2. **Authentication → Sign In / Providers → Email**: minimum password length **8**; email OTP expiration **600** seconds.
3. **Authentication → Rate Limits**: at least 60 seconds between emails to the same address (the default).
4. **Authentication → Emails → SMTP Settings**: turn on custom SMTP (for example Resend) with a sender on your own domain.
   Supabase's built-in mailer only sends a few emails per hour, which is fine for testing and nothing else.

Check: create an account with a fresh address in Hope → the email shows six digits → entering them signs you in.
Then **Forgot password?** → code → new password.

### Deleting an account (rebuild-plan 17.4)

`supabase/schema.sql` defines `delete_account()`, which the apps call from **Delete Account…**. It removes the caller's
rows from all five tables and then the user itself. The same file adds a foreign key from every table's `user_id` to
`auth.users`, so a device that is still signed in to a deleted account cannot write new rows.
After changing `schema.sql`, run the whole file again in the SQL Editor.

Check with a throwaway account: sign in, add a record, **Delete Account…**; in **Table Editor** its rows are gone and
**Authentication → Users** no longer lists it.

## 4. Give the values to the build

1. Open **Project Settings** → **API** (or **Data API** / **API Keys**).
2. Copy the **Project URL** (`https://<ref>.supabase.co`) and the **anon public** key
   (shown under "Legacy API keys" on newer projects; the newer **publishable** key `sb_publishable_…` also works).
   **Never** use the `service_role` / secret key — it bypasses row-level security.
3. In the repository root: `cp .env.example .env`, then fill in:

   ```
   SUPABASE_URL=https://<ref>.supabase.co
   SUPABASE_ANON_KEY=<anon or publishable key>
   ```

   `.env` is git-ignored. Both values end up inside the app, which is expected: they only identify the project;
   row-level security keeps each account's data private.
4. The very first time you create `.env`, run `touch src-tauri/build.rs` so Cargo notices it. Later edits to `.env` are picked up automatically.
5. `npm run tauri dev` (or build). **Settings → Sync** should now say "Not signed in" instead of "Not configured".

## 5. Sign in

In **Settings → Sync**, enter an email and password and click **Create Account** (first time) or **Sign In**.
Existing local data is merged into the account (newer edits win). Sign in with the same account on another device to sync both.

- Signing out keeps all local data.
- If a device last synced a *different* account, Hope asks before merging this device's data into the new one.
- The refresh token is stored in the system keychain (macOS Keychain / Windows Credential Manager).
  Unsigned builds may ask for keychain access after each update; choose **Always Allow**.

## 6. Release builds (GitHub Actions)

In the GitHub repository: **Settings → Secrets and variables → Actions → New repository secret**, add
`SUPABASE_URL` and `SUPABASE_ANON_KEY` with the same values. Without them, CI still builds a local-only app.
