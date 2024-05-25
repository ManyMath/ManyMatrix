use serde::{Deserialize, Serialize};

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
    pub mxc_uri: Option<String>,
    pub filename: Option<String>,
    pub file_size: Option<u64>,
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
