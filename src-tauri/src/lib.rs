mod break_reminder;
mod commands;
mod db;
mod error;
mod events;
mod overlay;
mod sync;
mod taskbar_icon;
mod tray;
mod vibrancy;

use tauri::{Manager, WindowEvent};
use tauri_specta::{collect_commands, collect_events, Builder};

#[cfg(any(debug_assertions, test))]
const BINDINGS_PATH: &str = "../src/lib/bindings.ts";

fn specta_builder() -> Builder<tauri::Wry> {
    Builder::<tauri::Wry>::new()
        .commands(collect_commands![
            commands::app::app_info,
            commands::setting::setting_get,
            commands::setting::setting_set,
            commands::activity::activity_list,
            commands::activity::activity_upsert,
            commands::activity::activity_archive,
            commands::activity::activity_reorder,
            commands::activity::activity_usage,
            commands::activity::activity_delete,
            commands::activity::activity_schedule_ensure,
            commands::session::session_start,
            commands::session::session_pause,
            commands::session::session_resume,
            commands::session::session_stop,
            commands::session::session_current,
            commands::session::session_list,
            commands::session::session_upsert,
            commands::session::session_delete,
            commands::session::session_save,
            commands::session::session_delete_many,
            commands::tray::tray_set_strings,
            commands::tray::timer_menu_popup,
            commands::break_reminder::break_set_strings,
            commands::overlay::overlay_show,
            commands::overlay::overlay_hide,
            commands::overlay::overlay_set_editing,
            commands::overlay::overlay_reset_position,
            commands::overlay::overlay_layout,
            commands::overlay::overlay_set_scale,
            commands::plan::plan_list,
            commands::plan::plan_upsert,
            commands::plan::plan_delete,
            commands::plan::plan_autolog,
            commands::schedule::ics_pick,
            commands::schedule::schedule_import,
            commands::journal::journal_list,
            commands::journal::journal_upsert,
            commands::journal::journal_delete,
            commands::data::data_export,
            commands::data::data_import,
            commands::data::data_wipe,
            commands::day::day_list,
            commands::day::day_set,
            commands::day::day_wake_now,
            commands::day::day_sleep_now,
            commands::tray::tray_set_day_action,
            commands::dialog::dialog_confirm,
            commands::dialog::dialog_alert,
            commands::sync::sync_status,
            commands::sync::sync_sign_in,
            commands::sync::sync_sign_up,
            commands::sync::sync_verify_sign_up,
            commands::sync::sync_resend_sign_up_code,
            commands::sync::sync_request_password_reset,
            commands::sync::sync_reset_password,
            commands::sync::sync_delete_account,
            commands::sync::sync_sign_out,
            commands::sync::sync_now,
        ])
        .events(collect_events![
            events::DataChanged,
            events::SettingChanged,
            overlay::OverlayEditing,
            sync::SyncStatusChanged
        ])
}

#[cfg(any(debug_assertions, test))]
fn export_bindings(builder: &Builder<tauri::Wry>) {
    builder
        .export(specta_typescript::Typescript::default(), BINDINGS_PATH)
        .expect("failed to export TypeScript bindings");
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = specta_builder();

    #[cfg(debug_assertions)]
    export_bindings(&builder);

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .invoke_handler(builder.invoke_handler())
        .on_menu_event(|app, event| tray::handle_menu_event(app, event.id().as_ref()))
        .on_window_event(|window, event| {
            // Closing the main window keeps Hope running in the menu bar / tray.
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
            // Dragging the overlay while editing: its backdrops (Windows) follow.
            if let WindowEvent::Moved(_) = event {
                if window.label() == overlay::LABEL {
                    overlay::on_moved(window.app_handle());
                }
            }
        })
        .setup(move |app| {
            builder.mount_events(app);

            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir)?;
            let database = db::Db::open(&dir.join("hope.db"))?;
            // Sample activities would be merged into the account at the first sign-in (and pushed to every
            // device), so only local-only debug builds get them.
            #[cfg(debug_assertions)]
            if !sync::configured() {
                db::activity::seed_samples_if_empty(&database.conn(), database.device_id(), db::now_ms())?;
            }
            app.manage(database);
            sync::init(app.handle())?;

            if let Some(main) = app.get_webview_window("main") {
                // Apply a forced light/dark choice before the page loads, so there is no flash.
                let appearance = db::setting::get(&app.state::<db::Db>().conn(), "theme.appearance")?;
                let theme = match appearance.as_deref() {
                    Some("light") => Some(tauri::Theme::Light),
                    Some("dark") => Some(tauri::Theme::Dark),
                    _ => None,
                };
                main.set_theme(theme)?;
                vibrancy::install(&main)?;
                taskbar_icon::install(&main)?;
            }
            tray::init(app.handle())?;
            overlay::init(app.handle())?;
            break_reminder::init(app.handle())?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Hope")
        .run(|app, event| {
            // Clicking the Dock icon brings the hidden window back.
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = event {
                tray::show_main_window(app);
            }
            let _ = (app, event);
        });
}

#[cfg(test)]
mod tests {
    /// `cargo test` keeps `src/lib/bindings.ts` in sync without launching the app.
    #[test]
    fn export_bindings() {
        super::export_bindings(&super::specta_builder());
    }
}
