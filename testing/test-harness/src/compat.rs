use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompatibilityReport {
    pub schema_version: u32,
    pub servers: Vec<ServerCompatibilityReport>,
}

impl CompatibilityReport {
    pub fn new(servers: Vec<ServerCompatibilityReport>) -> Self {
        Self {
            schema_version: 1,
            servers,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerCompatibilityReport {
    pub metadata: ServerMetadata,
    pub versions: VersionsProbe,
    pub behaviors: Vec<BehaviorResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerMetadata {
    pub kind: String,
    pub display_name: String,
    pub implementation_family: String,
    pub base_url: String,
    pub readiness_endpoint: String,
    pub registration_mode: String,
    pub source: ServerSourceMetadata,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerSourceMetadata {
    pub source_type: String,
    pub label: String,
    pub image: Option<String>,
    pub tag: Option<String>,
    pub digest: Option<String>,
    pub revision: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionsProbe {
    pub endpoint: String,
    pub http_status: Option<u16>,
    pub versions: Vec<String>,
    pub raw: Option<Value>,
    pub error: Option<String>,
}

impl VersionsProbe {
    pub fn failed(base_url: &str, error: impl Into<String>) -> Self {
        Self {
            endpoint: versions_endpoint(base_url),
            http_status: None,
            versions: Vec::new(),
            raw: None,
            error: Some(error.into()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BehaviorStatus {
    Pass,
    Fail,
    Skip,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BehaviorResult {
    pub behavior: String,
    pub status: BehaviorStatus,
    pub reason: Option<String>,
    pub details: Option<String>,
}

impl BehaviorResult {
    pub fn pass(behavior: impl Into<String>, details: impl Into<String>) -> Self {
        Self {
            behavior: behavior.into(),
            status: BehaviorStatus::Pass,
            reason: None,
            details: Some(details.into()),
        }
    }

    pub fn fail(behavior: impl Into<String>, reason: impl Into<String>) -> Self {
        Self {
            behavior: behavior.into(),
            status: BehaviorStatus::Fail,
            reason: Some(reason.into()),
            details: None,
        }
    }

    pub fn skip(behavior: impl Into<String>, reason: impl Into<String>) -> Self {
        let reason = reason.into();
        assert!(!reason.trim().is_empty(), "skip reason must not be empty");

        Self {
            behavior: behavior.into(),
            status: BehaviorStatus::Skip,
            reason: Some(reason),
            details: None,
        }
    }
}

pub async fn probe_versions(base_url: &str) -> Result<VersionsProbe> {
    let endpoint = versions_endpoint(base_url);
    let response = reqwest::Client::new()
        .get(&endpoint)
        .send()
        .await
        .with_context(|| format!("failed to fetch Matrix versions from {endpoint}"))?;

    let http_status = response.status().as_u16();
    let raw = response
        .json::<Value>()
        .await
        .with_context(|| format!("versions response from {endpoint} was not JSON"))?;
    let versions = raw
        .get("versions")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();

    Ok(VersionsProbe {
        endpoint,
        http_status: Some(http_status),
        versions,
        raw: Some(raw),
        error: None,
    })
}

fn versions_endpoint(base_url: &str) -> String {
    format!("{}/_matrix/client/versions", base_url.trim_end_matches('/'))
}
