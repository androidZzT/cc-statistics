use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager,
};

use crate::{restart_api, window};

pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open_i = MenuItem::with_id(app, "open_dashboard", "Open Dashboard", true, None::<&str>)?;
    let restart_i = MenuItem::with_id(app, "restart_api", "Restart API", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open_i, &restart_i, &quit_i])?;

    let mut builder = TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("CC Statistics")
        .show_menu_on_left_click(false);
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }

    builder
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open_dashboard" => {
                let _ = window::show_dashboard_window(app);
            }
            "restart_api" => {
                let _ = restart_api(app.clone(), app.state());
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let _ = window::show_dashboard_window(tray.app_handle());
            }
        })
        .build(app)?;

    Ok(())
}
