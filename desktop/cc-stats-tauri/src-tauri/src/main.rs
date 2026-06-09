use std::sync::Mutex;

use api_process::{ApiProcessManager, ApiStatus};
use health::ApiState;
use tauri::{AppHandle, Manager, State};

mod api_process;
mod health;
mod notifications;
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
    let (previous, status) = {
        let mut api = state.api.lock().expect("api state poisoned");
        let previous = api.status();
        let status = api.restart();
        (previous, status)
    };

    if status.state == ApiState::Running {
        if previous.state == ApiState::Failed {
            notifications::api_recovered(&app);
        }
        let _ = window::show_dashboard_window(&app);
    } else if let Some(error) = status.error.as_deref() {
        notifications::api_start_failed(&app, error);
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
            let mut api = ApiProcessManager::start_default();
            let initial_status = api.status();
            if let Some(error) = initial_status.error.as_deref() {
                notifications::api_start_failed(app.handle(), error);
            }
            app.manage(AppState {
                api: Mutex::new(api),
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
