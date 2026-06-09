use tauri::AppHandle;
use tauri_plugin_notification::NotificationExt;

pub fn api_start_failed(app: &AppHandle, error: &str) {
    notify(app, "CC Statistics API failed", error);
}

pub fn api_recovered(app: &AppHandle) {
    notify(
        app,
        "CC Statistics API recovered",
        "The local statistics dashboard is running again.",
    );
}

fn notify(app: &AppHandle, title: &str, body: &str) {
    let _ = app.notification().builder().title(title).body(body).show();
}
