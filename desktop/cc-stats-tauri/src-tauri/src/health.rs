use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    time::Duration,
};

use serde::Serialize;

const HEALTH_TIMEOUT: Duration = Duration::from_millis(800);

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ApiState {
    Starting,
    Running,
    Failed,
    Stopped,
}

pub fn is_api_healthy(api_url: &str) -> bool {
    let Some(port) = parse_local_api_port(api_url) else {
        return false;
    };
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, HEALTH_TIMEOUT) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(HEALTH_TIMEOUT));
    let _ = stream.set_write_timeout(Some(HEALTH_TIMEOUT));

    let request =
        format!("GET /api/health HTTP/1.0\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }

    let mut response = String::new();
    if stream.read_to_string(&mut response).is_err() {
        return false;
    }
    let compact = response.chars().filter(|ch| !ch.is_whitespace()).collect::<String>();
    (response.starts_with("HTTP/1.0 200") || response.starts_with("HTTP/1.1 200"))
        && compact.contains("\"status\":\"ok\"")
}

fn parse_local_api_port(api_url: &str) -> Option<u16> {
    let rest = api_url.strip_prefix("http://127.0.0.1:")?;
    let port = rest
        .chars()
        .take_while(|ch| ch.is_ascii_digit())
        .collect::<String>();
    if port.is_empty() {
        return None;
    }
    port.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::ApiState;

    #[test]
    fn api_state_serializes_to_frontend_contract() {
        assert_eq!(
            serde_json::to_string(&ApiState::Starting).unwrap(),
            "\"starting\""
        );
        assert_eq!(
            serde_json::to_string(&ApiState::Running).unwrap(),
            "\"running\""
        );
        assert_eq!(
            serde_json::to_string(&ApiState::Failed).unwrap(),
            "\"failed\""
        );
        assert_eq!(
            serde_json::to_string(&ApiState::Stopped).unwrap(),
            "\"stopped\""
        );
    }

    #[test]
    fn api_health_probe_detects_ok_response() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 512];
            let read = std::io::Read::read(&mut stream, &mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..read]);
            assert!(request.starts_with("GET /api/health HTTP/1.0"));
            std::io::Write::write_all(
                &mut stream,
                b"HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}",
            )
            .unwrap();
        });

        assert!(super::is_api_healthy(&format!("http://127.0.0.1:{port}/")));
        handle.join().unwrap();
    }

    #[test]
    fn api_health_probe_reads_split_status_response() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 512];
            let _ = std::io::Read::read(&mut stream, &mut request).unwrap();
            std::io::Write::write_all(&mut stream, b"HTTP/1.1 ").unwrap();
            std::thread::sleep(std::time::Duration::from_millis(75));
            std::io::Write::write_all(
                &mut stream,
                b"200 OK\r\nContent-Length: 15\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}",
            )
            .unwrap();
        });

        assert!(super::is_api_healthy(&format!("http://127.0.0.1:{port}/")));
        handle.join().unwrap();
    }

    #[test]
    fn api_health_probe_rejects_unrelated_local_200_response() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 512];
            let _ = std::io::Read::read(&mut stream, &mut request).unwrap();
            std::io::Write::write_all(
                &mut stream,
                b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world",
            )
            .unwrap();
        });

        assert!(!super::is_api_healthy(&format!("http://127.0.0.1:{port}/")));
        handle.join().unwrap();
    }

    #[test]
    fn api_health_probe_rejects_non_local_url() {
        assert!(!super::is_api_healthy("http://localhost:61234/"));
    }
}
