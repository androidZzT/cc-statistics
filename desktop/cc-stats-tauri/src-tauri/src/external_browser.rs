use crate::{api_process::ApiStatus, health::ApiState};

pub fn dashboard_url_for_open(status: &ApiStatus) -> Result<String, String> {
    if status.state != ApiState::Running {
        return Err(format_not_ready(status.error.as_deref()));
    }

    let url = status
        .url
        .as_deref()
        .ok_or_else(|| format_not_ready(Some("missing dashboard URL")))?;
    if !is_local_dashboard_url(url) {
        return Err(format!("dashboard URL is not local: {url}"));
    }
    Ok(url.to_string())
}

pub fn open_dashboard_url(url: &str) -> Result<(), String> {
    if !is_local_dashboard_url(url) {
        return Err(format!("dashboard URL is not local: {url}"));
    }
    open_url(url)
}

fn format_not_ready(error: Option<&str>) -> String {
    match error {
        Some(error) if !error.is_empty() => format!("dashboard is not ready: {error}"),
        _ => "dashboard is not ready".to_string(),
    }
}

fn is_local_dashboard_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("http://127.0.0.1:") else {
        return false;
    };
    let digit_count = rest.chars().take_while(|ch| ch.is_ascii_digit()).count();
    if digit_count == 0 {
        return false;
    }
    let suffix = &rest[digit_count..];
    suffix.is_empty() || suffix.starts_with('/')
}

#[cfg(target_os = "windows")]
fn open_url(url: &str) -> Result<(), String> {
    use std::{ffi::OsStr, iter, os::windows::ffi::OsStrExt, ptr};

    use windows_sys::Win32::{UI::Shell::ShellExecuteW, UI::WindowsAndMessaging::SW_SHOWNORMAL};

    fn wide(value: &str) -> Vec<u16> {
        OsStr::new(value)
            .encode_wide()
            .chain(iter::once(0))
            .collect()
    }

    let operation = wide("open");
    let target = wide(url);
    let result = unsafe {
        ShellExecuteW(
            ptr::null_mut(),
            operation.as_ptr(),
            target.as_ptr(),
            ptr::null(),
            ptr::null(),
            SW_SHOWNORMAL,
        )
    };

    let code = result as isize;
    if code <= 32 {
        return Err(format!(
            "failed to open dashboard URL: ShellExecuteW returned {code}"
        ));
    }
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn open_url(_url: &str) -> Result<(), String> {
    Err("opening the dashboard externally is only implemented for Windows".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(state: ApiState, url: Option<&str>, error: Option<&str>) -> ApiStatus {
        ApiStatus {
            state,
            url: url.map(str::to_string),
            error: error.map(str::to_string),
        }
    }

    #[test]
    fn dashboard_url_for_open_uses_running_local_api_url() {
        let status = status(ApiState::Running, Some("http://127.0.0.1:61234/"), None);

        assert_eq!(
            dashboard_url_for_open(&status),
            Ok("http://127.0.0.1:61234/".to_string())
        );
    }

    #[test]
    fn dashboard_url_for_open_rejects_non_local_urls() {
        let status = status(ApiState::Running, Some("https://example.com/"), None);

        assert!(dashboard_url_for_open(&status).is_err());
    }

    #[test]
    fn dashboard_url_for_open_reports_failed_api_error() {
        let status = status(ApiState::Failed, None, Some("python missing"));

        assert_eq!(
            dashboard_url_for_open(&status),
            Err("dashboard is not ready: python missing".to_string())
        );
    }
}
