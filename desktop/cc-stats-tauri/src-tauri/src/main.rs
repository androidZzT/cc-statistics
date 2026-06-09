#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    sync::Mutex,
    thread,
    time::Duration,
};

use api_process::{ApiProcessManager, ApiStatus};
use health::ApiState;
use tauri::{AppHandle, Manager, State};

mod api_process;
mod external_browser;
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
fn open_dashboard(state: State<'_, AppState>) -> Result<(), String> {
    let status = {
        let mut api = state.api.lock().expect("api state poisoned");
        api.status()
    };
    let url = external_browser::dashboard_url_for_open(&status)?;
    external_browser::open_dashboard_url(&url)
}

fn start_api_health_monitor(app: AppHandle, initial_state: ApiState) {
    thread::spawn(move || {
        let mut last_state = initial_state;
        loop {
            thread::sleep(Duration::from_secs(3));
            let status = {
                let state = app.state::<AppState>();
                let mut api = state.api.lock().expect("api state poisoned");
                api.status()
            };

            if status.state == ApiState::Failed && last_state != ApiState::Failed {
                if let Some(error) = status.error.as_deref() {
                    notifications::api_start_failed(&app, error);
                }
            }
            last_state = status.state;
        }
    });
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
            start_api_health_monitor(app.handle().clone(), initial_status.state);
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
