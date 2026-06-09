use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ApiState {
    Starting,
    Running,
    Failed,
    Stopped,
}

#[cfg(test)]
mod tests {
    use super::ApiState;

    #[test]
    fn api_state_serializes_to_frontend_contract() {
        assert_eq!(serde_json::to_string(&ApiState::Starting).unwrap(), "\"starting\"");
        assert_eq!(serde_json::to_string(&ApiState::Running).unwrap(), "\"running\"");
        assert_eq!(serde_json::to_string(&ApiState::Failed).unwrap(), "\"failed\"");
        assert_eq!(serde_json::to_string(&ApiState::Stopped).unwrap(), "\"stopped\"");
    }
}
