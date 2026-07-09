use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Matrix homeserver version and capability signals.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerCapabilities {
    pub homeserver: String,
    pub versions: Vec<String>,
    pub unstable_features: BTreeMap<String, bool>,
    pub raw_versions: Value,
    pub raw_capabilities: Value,
    pub capabilities_authenticated: bool,
    pub supports_authenticated_media: bool,
    pub supports_refresh_tokens: bool,
}

impl ServerCapabilities {
    pub fn from_raw(
        homeserver: String,
        versions: Vec<String>,
        unstable_features: BTreeMap<String, bool>,
        raw_versions: Value,
        raw_capabilities: Option<Value>,
    ) -> Self {
        let supports_authenticated_media = supports_matrix_version(&versions, 1, 11)
            || unstable_feature_enabled(&unstable_features, "org.matrix.msc3916")
            || unstable_feature_enabled(&unstable_features, "org.matrix.msc3916.stable");
        let supports_refresh_tokens = supports_matrix_version(&versions, 1, 3)
            || unstable_feature_enabled(&unstable_features, "org.matrix.msc2918")
            || unstable_feature_enabled(&unstable_features, "org.matrix.msc2918.stable")
            || unstable_feature_enabled(&unstable_features, "org.matrix.msc2918.refresh_token");
        let capabilities_authenticated = raw_capabilities.is_some();

        Self {
            homeserver,
            versions,
            unstable_features,
            raw_versions,
            raw_capabilities: raw_capabilities.unwrap_or(Value::Null),
            capabilities_authenticated,
            supports_authenticated_media,
            supports_refresh_tokens,
        }
    }
}

fn unstable_feature_enabled(features: &BTreeMap<String, bool>, key: &str) -> bool {
    features.get(key).copied().unwrap_or(false)
}

fn supports_matrix_version(versions: &[String], required_major: u64, required_minor: u64) -> bool {
    versions.iter().any(|version| {
        parse_matrix_version(version).is_some_and(|(major, minor)| {
            major > required_major || (major == required_major && minor >= required_minor)
        })
    })
}

fn parse_matrix_version(version: &str) -> Option<(u64, u64)> {
    let version = version.strip_prefix('v')?;
    let (major, minor) = version.split_once('.')?;
    Some((major.parse().ok()?, minor.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_capabilities_serializes_version_and_support_booleans() {
        let capabilities = ServerCapabilities::from_raw(
            "http://localhost:8008".to_owned(),
            vec!["v1.1".to_owned(), "v1.11".to_owned()],
            BTreeMap::new(),
            serde_json::json!({
                "versions": ["v1.1", "v1.11"],
                "unstable_features": {}
            }),
            None,
        );

        let json = serde_json::to_value(&capabilities).unwrap();
        assert!(json.get("versions").is_some());
        assert_eq!(json["supports_authenticated_media"], true);
        assert_eq!(json["supports_refresh_tokens"], true);
        assert_eq!(json["capabilities_authenticated"], false);
    }
}

/// Summary of a joined room for display in room lists.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoomSummary {
    pub room_id: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
    pub last_message: Option<LastMessage>,
    pub unread_count: u64,
}

/// Preview of the most recent message in a room.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LastMessage {
    pub sender: String,
    pub body: String,
    pub timestamp: u64, // unix millis
}

/// Options for creating a new room.
#[derive(Debug, Clone, Default)]
pub struct CreateRoomOptions {
    pub name: Option<String>,
    pub topic: Option<String>,
    pub invite: Vec<String>,
    pub visibility: RoomVisibility,
}

/// Room visibility for creation.
#[derive(Debug, Clone, Default)]
pub enum RoomVisibility {
    #[default]
    Private,
    Public,
}

/// A received message event, used by event handlers and pagination.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageEvent {
    pub event_id: String,
    pub room_id: String,
    pub sender: String,
    pub body: String,
    pub formatted_body: Option<String>,
    pub msgtype: String,
    pub timestamp: u64,
    pub in_reply_to: Option<String>,
    pub thread_root: Option<String>,
    pub replaces_event_id: Option<String>,
    pub edited_at: Option<u64>,
    pub mxc_uri: Option<String>,
    pub filename: Option<String>,
    pub file_size: Option<u64>,
}

/// A received custom (non-standard) message-like event: any Matrix event type that isn't
/// one of this crate's fixed shapes (`m.room.message`, `m.reaction`, etc). `content` is the
/// event's raw JSON content, verbatim, since a custom event type has no fixed schema for
/// this crate to deserialize into.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomEvent {
    pub event_id: String,
    pub room_id: String,
    pub sender: String,
    pub event_type: String,
    pub content: Value,
    pub timestamp: u64,
}

/// Result of paginating messages in a room.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaginatedMessages {
    pub messages: Vec<MessageEvent>,
    pub end_token: Option<String>,
}

/// A received reaction event.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReactionEvent {
    pub event_id: String,
    pub room_id: String,
    pub sender: String,
    pub relates_to_event_id: String,
    pub key: String,
    pub timestamp: u64,
}

/// Emoji pair for SAS verification display.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SasEmoji {
    pub symbol: String,
    pub description: String,
}

/// SAS verification emoji set (7 emojis to compare).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SasEmojis {
    pub emojis: Vec<SasEmoji>,
}

/// A received read receipt event.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReceiptEvent {
    pub room_id: String,
    pub user_id: String,
    pub event_id: String,
    pub receipt_type: String,
    pub timestamp: Option<u64>,
}
