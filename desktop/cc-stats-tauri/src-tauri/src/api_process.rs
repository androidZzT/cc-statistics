use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    sync::mpsc,
    thread,
    time::Duration,
};

use serde::{Deserialize, Serialize};

use crate::health::ApiState;

#[derive(Clone, Debug, Serialize)]
pub struct ApiStatus {
    pub state: ApiState,
    pub url: Option<String>,
    pub error: Option<String>,
}

pub struct ApiProcessManager {
    child: Option<Child>,
    status: ApiStatus,
}

impl ApiProcessManager {
    pub fn start_default() -> Self {
        let mut manager = Self {
            child: None,
            status: ApiStatus {
                state: ApiState::Starting,
                url: None,
                error: None,
            },
        };
        match start_python_api() {
            Ok((child, url)) => {
                manager.child = Some(child);
                manager.status = ApiStatus {
                    state: ApiState::Running,
                    url: Some(url),
                    error: None,
                };
                manager
            }
            Err(error) => Self::failed(error),
        }
    }

    pub fn failed(error: String) -> Self {
        Self {
            child: None,
            status: ApiStatus {
                state: ApiState::Failed,
                url: None,
                error: Some(error),
            },
        }
    }

    pub fn status(&self) -> ApiStatus {
        self.status.clone()
    }

    pub fn restart(&mut self) -> ApiStatus {
        self.stop();
        let mut next = Self::start_default();
        self.child = next.child.take();
        self.status = next.status.clone();
        self.status()
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.status.state = ApiState::Stopped;
    }
}

impl Drop for ApiProcessManager {
    fn drop(&mut self) {
        self.stop();
    }
}

pub fn candidate_python_commands() -> Vec<Vec<String>> {
    if cfg!(windows) {
        vec![
            vec!["py".to_string(), "-3".to_string()],
            vec!["python".to_string()],
            vec!["python3".to_string()],
        ]
    } else {
        vec![vec!["python3".to_string()], vec!["python".to_string()]]
    }
}

pub fn build_api_command(python_command: &[String]) -> Command {
    let mut command = Command::new(&python_command[0]);
    for arg in &python_command[1..] {
        command.arg(arg);
    }
    command.args(["-m", "cc_stats_web", "--no-browser", "--json"]);
    command
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

fn start_python_api() -> Result<(Child, String), String> {
    for python in candidate_python_commands() {
        match spawn_with_python(&python) {
            Ok(started) => return Ok(started),
            Err(_) => continue,
        }
    }
    Err("Unable to start cc_stats_web with python, python3, or py -3".to_string())
}

fn spawn_with_python(python: &[String]) -> Result<(Child, String), String> {
    let mut command = build_api_command(python);
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|err| format!("failed to spawn {}: {err}", python.join(" ")))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "cc_stats_web stdout was not captured".to_string())?;
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines().map_while(Result::ok) {
            if let Some(url) = parse_startup_url(&line) {
                let _ = tx.send(url);
                return;
            }
        }
    });

    match rx.recv_timeout(Duration::from_secs(8)) {
        Ok(url) => Ok((child, url)),
        Err(err) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(format!("cc_stats_web did not report a startup URL: {err}"))
        }
    }
}

#[derive(Debug, Deserialize)]
struct StartupPayload {
    event: String,
    url: String,
}

#[cfg(test)]
mod tests {
    use super::{build_api_command, candidate_python_commands, parse_startup_url};

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
    fn candidate_python_commands_are_not_empty() {
        assert!(!candidate_python_commands().is_empty());
    }
}
