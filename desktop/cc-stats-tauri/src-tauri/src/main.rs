#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    path::PathBuf,
    sync::Mutex,
    thread,
    time::Duration,
};

use api_process::{ApiProcessManager, ApiStatus};
use health::{is_api_healthy, ApiState};
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
    probe_api_status(&state.api)
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
    let status = probe_api_status(&state.api);
    let url = external_browser::dashboard_url_for_open(&status)?;
    external_browser::open_dashboard_url(&url)
}

pub fn open_dashboard_for_app(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    let status = probe_api_status(&state.api);
    let url = external_browser::dashboard_url_for_open(&status)?;
    external_browser::open_dashboard_url(&url)
}

pub fn quit_app(app: &AppHandle) {
    let state = app.state::<AppState>();
    if let Ok(mut api) = state.api.lock() {
        api.stop();
    }
    app.exit(0);
}

fn probe_api_status(api: &Mutex<ApiProcessManager>) -> ApiStatus {
    let (snapshot, probe_url) = {
        let mut api = api.lock().expect("api state poisoned");
        let snapshot = api.status();
        let probe_url = api.health_probe_url();
        (snapshot, probe_url)
    };

    let Some(url) = probe_url else {
        return snapshot;
    };

    let healthy = is_api_healthy(&url);
    let mut api = api.lock().expect("api state poisoned");
    api.apply_health_probe(&url, healthy)
}

fn bundled_python_source_dir(app: &AppHandle) -> Option<PathBuf> {
    app.path()
        .resource_dir()
        .ok()
        .map(|resource_dir| resource_dir.join("python"))
        .filter(|python_dir| python_dir.exists())
}

fn start_api_health_monitor(app: AppHandle, initial_state: ApiState) {
    thread::spawn(move || {
        let mut last_state = initial_state;
        loop {
            thread::sleep(Duration::from_secs(3));
            let state = app.state::<AppState>();
            let status = probe_api_status(&state.api);

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
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            let _ = open_dashboard_for_app(app);
        }))
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            let mut api = ApiProcessManager::start_default_with_python_source(
                bundled_python_source_dir(app.handle()),
            );
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
