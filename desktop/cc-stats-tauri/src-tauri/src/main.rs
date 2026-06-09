use std::sync::Mutex;

use api_process::{ApiProcessManager, ApiStatus};
use tauri::{AppHandle, Manager, State};

mod api_process;
mod health;
mod tray;
mod window;

struct AppState {
    api: Mutex<ApiProcessManager>,
}

#[tauri::command]
fn api_status(state: State<'_, AppState>) -> ApiStatus {
    state.api.lock().expect("api state poisoned").status()
}

#[tauri::command]
fn restart_api(app: AppHandle, state: State<'_, AppState>) -> Result<ApiStatus, String> {
    let status = state.api.lock().expect("api state poisoned").restart();
    if status.error.is_none() {
        let _ = window::show_dashboard_window(&app);
    }
    Ok(status)
}

#[tauri::command]
fn open_dashboard(app: AppHandle) -> Result<(), String> {
    window::show_dashboard_window(&app)
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            app.manage(AppState {
                api: Mutex::new(ApiProcessManager::start_default()),
            });
            tray::build_tray(app.handle())?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            api_status,
            restart_api,
            open_dashboard
        ])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running cc-statistics Windows tray app");
}
