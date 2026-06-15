use std::{
    env,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc,
    thread,
    thread::JoinHandle,
    time::{Duration, Instant},
};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

use serde::{Deserialize, Serialize};

use crate::health::{is_api_healthy, ApiState};

const HEALTH_FAILURE_THRESHOLD: u8 = 3;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

#[derive(Clone, Debug, Serialize)]
pub struct ApiStatus {
    pub state: ApiState,
    pub url: Option<String>,
    pub error: Option<String>,
}

pub struct ApiProcessManager {
    child: Option<Child>,
    health_failures: u8,
    python_source_dir: Option<PathBuf>,
    status: ApiStatus,
}

impl ApiProcessManager {
    pub fn start_default_with_python_source(python_source_dir: Option<PathBuf>) -> Self {
        let mut manager = Self {
            child: None,
            health_failures: 0,
            python_source_dir,
            status: ApiStatus {
                state: ApiState::Starting,
                url: None,
                error: None,
            },
        };
        match start_python_api(manager.python_source_dir.as_deref()) {
            Ok((child, url)) => {
                manager.child = Some(child);
                manager.status = ApiStatus {
                    state: ApiState::Running,
                    url: Some(url),
                    error: None,
                };
                manager
            }
            Err(error) => Self::failed_with_python_source(error, manager.python_source_dir.clone()),
        }
    }

    fn failed_with_python_source(error: String, python_source_dir: Option<PathBuf>) -> Self {
        Self {
            child: None,
            health_failures: 0,
            python_source_dir,
            status: ApiStatus {
                state: ApiState::Failed,
                url: None,
                error: Some(error),
            },
        }
    }

    pub fn status(&mut self) -> ApiStatus {
        self.refresh_child_status();
        self.status.clone()
    }

    pub fn health_probe_url(&mut self) -> Option<String> {
        self.refresh_child_status();
        if self.child.is_none() {
            return None;
        }
        if !matches!(self.status.state, ApiState::Running | ApiState::Failed) {
            return None;
        }
        self.status.url.clone()
    }

    pub fn apply_health_probe(&mut self, url: &str, healthy: bool) -> ApiStatus {
        self.refresh_child_status();
        if self.child.is_none() || self.status.url.as_deref() != Some(url) {
            return self.status.clone();
        }

        if healthy {
            self.health_failures = 0;
            self.status.state = ApiState::Running;
            self.status.error = None;
            return self.status.clone();
        }

        if self.status.state == ApiState::Running {
            self.health_failures = self.health_failures.saturating_add(1);
            if self.health_failures >= HEALTH_FAILURE_THRESHOLD {
                self.status.state = ApiState::Failed;
                self.status.error = Some(format!("cc_stats_web health check failed for {url}"));
            }
        }

        self.status.clone()
    }

    pub fn restart(&mut self) -> ApiStatus {
        self.stop();
        let mut next = Self::start_default_with_python_source(self.python_source_dir.clone());
        self.child = next.child.take();
        self.health_failures = next.health_failures;
        self.status = next.status.clone();
        self.status()
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.health_failures = 0;
        self.status.state = ApiState::Stopped;
    }

    fn refresh_child_status(&mut self) {
        if !matches!(
            self.status.state,
            ApiState::Running | ApiState::Failed | ApiState::Starting
        ) {
            return;
        }

        if let Some(child) = self.child.as_mut() {
            match child.try_wait() {
                Ok(Some(exit_status)) => {
                    self.child = None;
                    self.health_failures = HEALTH_FAILURE_THRESHOLD;
                    self.status.state = ApiState::Failed;
                    self.status.error = Some(format!("cc_stats_web exited with {exit_status}"));
                    return;
                }
                Ok(None) => {}
                Err(error) => {
                    self.health_failures = HEALTH_FAILURE_THRESHOLD;
                    self.status.state = ApiState::Failed;
                    self.status.error = Some(format!("failed to inspect cc_stats_web: {error}"));
                    return;
                }
            }
        }

        if self.child.is_none() {
            if self.status.state == ApiState::Running {
                self.health_failures = HEALTH_FAILURE_THRESHOLD;
                self.status.state = ApiState::Failed;
                self.status.error = Some("cc_stats_web process is not running".to_string());
            }
            return;
        }

        if self.status.url.is_none() {
            self.health_failures = HEALTH_FAILURE_THRESHOLD;
            self.status.state = ApiState::Failed;
            self.status.error =
                Some("cc_stats_web health check failed: missing API URL".to_string());
        }
    }

    #[cfg(test)]
    fn running_for_test(url: &str) -> Self {
        Self {
            child: None,
            health_failures: 0,
            python_source_dir: None,
            status: ApiStatus {
                state: ApiState::Running,
                url: Some(url.to_string()),
                error: None,
            },
        }
    }

    #[cfg(test)]
    fn running_with_child_for_test(url: &str, child: Child) -> Self {
        Self {
            child: Some(child),
            health_failures: 0,
            python_source_dir: None,
            status: ApiStatus {
                state: ApiState::Running,
                url: Some(url.to_string()),
                error: None,
            },
        }
    }
}

impl Drop for ApiProcessManager {
    fn drop(&mut self) {
        self.stop();
    }
}

pub fn candidate_python_commands() -> Vec<Vec<String>> {
    let configured_python = env::var("CC_STATS_PYTHON")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    candidate_python_commands_for_platform(cfg!(windows), configured_python)
}

pub fn candidate_python_commands_for_platform(
    is_windows: bool,
    configured_python: Option<String>,
) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    if let Some(python) = configured_python {
        push_python_command(&mut commands, vec![python]);
    }

    if is_windows {
        push_python_command(&mut commands, vec!["pythonw".to_string()]);
        push_python_command(&mut commands, vec!["python".to_string()]);
        push_python_command(&mut commands, vec!["py".to_string(), "-3".to_string()]);
        push_python_command(&mut commands, vec!["python3".to_string()]);
    } else {
        push_python_command(&mut commands, vec!["/opt/homebrew/bin/python3".to_string()]);
        push_python_command(&mut commands, vec!["/usr/local/bin/python3".to_string()]);
        push_python_command(&mut commands, vec!["python3".to_string()]);
        push_python_command(&mut commands, vec!["python".to_string()]);
    }
    commands
}

fn push_python_command(commands: &mut Vec<Vec<String>>, command: Vec<String>) {
    if !commands.contains(&command) {
        commands.push(command);
    }
}

#[cfg(test)]
pub fn build_api_command(python_command: &[String]) -> Command {
    build_api_command_with_python_source(python_command, None)
}

pub fn build_api_command_with_python_source(
    python_command: &[String],
    python_source_dir: Option<&Path>,
) -> Command {
    let mut command = Command::new(&python_command[0]);
    for arg in &python_command[1..] {
        command.arg(arg);
    }
    command.args(["-m", "cc_stats_web", "--no-browser", "--json"]);
    command.env("CC_STATS_DESKTOP_SHELL", "1");
    apply_python_source_dir(&mut command, python_source_dir);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

fn apply_python_source_dir(command: &mut Command, python_source_dir: Option<&Path>) {
    let Some(source_dir) = python_source_dir else {
        return;
    };
    let mut paths = vec![source_dir.to_path_buf()];
    if let Some(existing) = env::var_os("PYTHONPATH") {
        paths.extend(env::split_paths(&existing));
    }
    if let Ok(value) = env::join_paths(paths) {
        command.env("PYTHONPATH", value);
    }
}

pub fn parse_startup_url(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(payload) = serde_json::from_str::<StartupPayload>(trimmed) {
        if payload.event == "cc_stats_web_started" && payload.url.starts_with("http://127.0.0.1:") {
            return Some(payload.url);
        }
    }
    if let Some(idx) = trimmed.find("http://127.0.0.1:") {
        return Some(trimmed[idx..].trim().to_string());
    }
    None
}

fn start_python_api(python_source_dir: Option<&Path>) -> Result<(Child, String), String> {
    let commands = candidate_python_commands();
    let mut errors = Vec::new();
    for python in &commands {
        match spawn_with_python(python, python_source_dir) {
            Ok(started) => return Ok(started),
            Err(error) => errors.push(format!("{}: {error}", python.join(" "))),
        }
    }

    let attempted = commands
        .iter()
        .map(|command| command.join(" "))
        .collect::<Vec<_>>()
        .join(", ");
    if errors.is_empty() {
        Err(format!("Unable to start cc_stats_web with {attempted}"))
    } else {
        Err(format!(
            "Unable to start cc_stats_web with {attempted}; attempts: {}",
            errors.join(" | ")
        ))
    }
}

fn spawn_with_python(
    python: &[String],
    python_source_dir: Option<&Path>,
) -> Result<(Child, String), String> {
    let mut command = build_api_command_with_python_source(python, python_source_dir);
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|err| format!("failed to spawn {}: {err}", python.join(" ")))?;
    let stderr_handle = capture_stderr(&mut child);

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "cc_stats_web stdout was not captured".to_string())?;
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        let mut sent_url = false;
        for line in reader.lines().map_while(Result::ok) {
            if !sent_url {
                if let Some(url) = parse_startup_url(&line) {
                    let _ = tx.send(url);
                    sent_url = true;
                }
            }
        }
    });

    match rx.recv_timeout(Duration::from_secs(8)) {
        Ok(url) => match wait_for_api_health(&mut child, &url) {
            Ok(()) => Ok((child, url)),
            Err(error) => Err(fail_child_with_stderr(child, stderr_handle, error)),
        },
        Err(err) => Err(fail_child_with_stderr(
            child,
            stderr_handle,
            format!("cc_stats_web did not report a startup URL: {err}"),
        )),
    }
}

fn capture_stderr(child: &mut Child) -> Option<JoinHandle<String>> {
    let stderr = child.stderr.take()?;
    Some(thread::spawn(move || {
        let reader = BufReader::new(stderr);
        reader
            .lines()
            .map_while(Result::ok)
            .collect::<Vec<_>>()
            .join("\n")
    }))
}

fn fail_child_with_stderr(
    mut child: Child,
    stderr_handle: Option<JoinHandle<String>>,
    message: String,
) -> String {
    let _ = child.kill();
    let _ = child.wait();
    let stderr = stderr_handle
        .and_then(|handle| handle.join().ok())
        .unwrap_or_default();
    let stderr = stderr.trim();
    if stderr.is_empty() {
        message
    } else {
        format!("{message}; stderr: {stderr}")
    }
}

fn wait_for_api_health(child: &mut Child, url: &str) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(exit_status)) => {
                return Err(format!(
                    "cc_stats_web exited before becoming healthy: {exit_status}"
                ));
            }
            Ok(None) => {}
            Err(error) => {
                return Err(format!(
                    "failed to inspect cc_stats_web during startup: {error}"
                ));
            }
        }

        if is_api_healthy(url) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(150));
    }

    Err(format!("cc_stats_web did not become healthy at {url}"))
}

#[derive(Debug, Deserialize)]
struct StartupPayload {
    event: String,
    url: String,
}

#[cfg(test)]
mod tests {
    use super::{
        build_api_command, build_api_command_with_python_source, candidate_python_commands,
        candidate_python_commands_for_platform, capture_stderr, parse_startup_url,
        spawn_with_python, ApiProcessManager, ApiStatus,
    };
    use crate::health::ApiState;
    use std::{
        path::PathBuf,
        process::{Child, Command, Stdio},
    };

    #[test]
    fn parses_structured_startup_json() {
        let url = parse_startup_url(
            r#"{"event":"cc_stats_web_started","host":"127.0.0.1","port":61234,"url":"http://127.0.0.1:61234/"}"#,
        );

        assert_eq!(url.as_deref(), Some("http://127.0.0.1:61234/"));
    }

    #[test]
    fn parses_legacy_human_startup_line() {
        let url = parse_startup_url("CC Stats Web Dashboard: http://127.0.0.1:61234/");

        assert_eq!(url.as_deref(), Some("http://127.0.0.1:61234/"));
    }

    #[test]
    fn api_command_uses_structured_no_browser_startup() {
        let python = vec!["python3".to_string()];
        let command = build_api_command(&python);
        let args = command
            .get_args()
            .map(|arg| arg.to_string_lossy().to_string())
            .collect::<Vec<_>>();

        assert_eq!(command.get_program().to_string_lossy(), "python3");
        assert_eq!(args, ["-m", "cc_stats_web", "--no-browser", "--json"]);
    }

    #[test]
    fn api_command_sets_pythonpath_to_bundled_source_dir() {
        let python = vec!["python3".to_string()];
        let source_dir = if cfg!(windows) {
            PathBuf::from(r"C:\cc-statistics\resources\python")
        } else {
            PathBuf::from("/tmp/cc-statistics/resources/python")
        };
        let command = build_api_command_with_python_source(&python, Some(&source_dir));

        assert!(command
            .get_envs()
            .any(|(key, value)| key == "PYTHONPATH" && value.is_some()));
    }

    #[test]
    fn api_command_marks_python_dashboard_as_desktop_shell() {
        let python = vec!["python3".to_string()];
        let command = build_api_command(&python);

        assert!(command.get_envs().any(|(key, value)| {
            key == "CC_STATS_DESKTOP_SHELL" && value == Some(std::ffi::OsStr::new("1"))
        }));
    }

    #[test]
    fn capture_stderr_takes_child_pipe_to_prevent_blocking_api() {
        let mut command = if cfg!(windows) {
            let mut command = Command::new("cmd");
            command.args(["/C", "echo noisy 1>&2"]);
            command
        } else {
            let mut command = Command::new("sh");
            command.args(["-c", "echo noisy >&2"]);
            command
        };
        command.stderr(Stdio::piped());
        let mut child = command.spawn().unwrap();

        let handle = capture_stderr(&mut child);

        assert!(child.stderr.is_none());
        let _ = child.wait();
        assert_eq!(
            handle.and_then(|handle| handle.join().ok()).as_deref(),
            Some("noisy")
        );
    }

    #[test]
    fn candidate_python_commands_are_not_empty() {
        assert!(!candidate_python_commands().is_empty());
    }

    #[test]
    fn windows_prefers_pythonw_to_avoid_console_window() {
        let commands = candidate_python_commands_for_platform(true, None);

        assert_eq!(commands[0], vec!["pythonw".to_string()]);
    }

    #[test]
    fn candidate_python_commands_prefers_configured_python() {
        let commands =
            candidate_python_commands_for_platform(false, Some("/custom/bin/python3".to_string()));

        assert_eq!(commands[0], vec!["/custom/bin/python3".to_string()]);
    }

    #[test]
    fn candidate_python_commands_include_homebrew_paths_on_macos() {
        let commands = candidate_python_commands_for_platform(false, None);

        assert!(commands.contains(&vec!["/opt/homebrew/bin/python3".to_string()]));
        assert!(commands.contains(&vec!["/usr/local/bin/python3".to_string()]));
    }

    #[test]
    fn startup_failure_includes_stderr_output() {
        let command = if cfg!(windows) {
            vec![
                "cmd".to_string(),
                "/C".to_string(),
                "echo module missing 1>&2 & exit /B 42".to_string(),
            ]
        } else {
            vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "echo 'module missing' >&2; exit 42".to_string(),
            ]
        };
        let err = spawn_with_python(&command, None).unwrap_err();

        assert!(err.contains("module missing"), "{err}");
    }

    #[test]
    fn status_marks_running_without_owned_child_failed() {
        let mut manager = ApiProcessManager::running_for_test("http://localhost:61234/");

        let status = manager.status();

        assert_eq!(status.state, ApiState::Failed);
        assert_eq!(status.url.as_deref(), Some("http://localhost:61234/"));
        assert_eq!(
            status.error.as_deref(),
            Some("cc_stats_web process is not running")
        );
    }

    #[test]
    fn status_marks_running_manager_failed_after_repeated_health_probe_failures() {
        let child = sleep_child();
        let mut manager =
            ApiProcessManager::running_with_child_for_test("http://localhost:61234/", child);

        manager.apply_health_probe("http://localhost:61234/", false);
        manager.apply_health_probe("http://localhost:61234/", false);
        let status = manager.apply_health_probe("http://localhost:61234/", false);

        assert_eq!(status.state, ApiState::Failed);
        assert_eq!(status.url.as_deref(), Some("http://localhost:61234/"));
        assert!(status.error.unwrap().contains("health check failed"));
    }

    #[test]
    fn failed_manager_without_owned_child_does_not_recover_from_reused_port() {
        let url = "http://127.0.0.1:61234/".to_string();
        let mut manager = ApiProcessManager {
            child: None,
            health_failures: 3,
            python_source_dir: None,
            status: ApiStatus {
                state: ApiState::Failed,
                url: Some(url.clone()),
                error: Some("cc_stats_web health check failed".to_string()),
            },
        };

        let status = manager.apply_health_probe(&url, true);

        assert_eq!(status.state, ApiState::Failed);
        assert_eq!(status.url.as_deref(), Some(url.as_str()));
        assert_eq!(
            status.error.as_deref(),
            Some("cc_stats_web health check failed")
        );
    }

    fn sleep_child() -> Child {
        if cfg!(windows) {
            let mut command = Command::new("cmd");
            command.args(["/C", "ping -n 6 127.0.0.1 > nul"]);
            command
        } else {
            let mut command = Command::new("sh");
            command.args(["-c", "sleep 5"]);
            command
        }
        .spawn()
        .unwrap()
    }
}
