mod client;
mod error;
mod session;
mod types;

pub use client::ManyMatrixClient;
pub use error::Error;
pub use session::StoredSession;
pub use types::{
    CreateRoomOptions, CustomEvent, LastMessage, MessageEvent, PaginatedMessages, ReactionEvent,
    ReceiptEvent, RoomDetails, RoomInvite, RoomSummary, RoomVisibility, SasEmoji, SasEmojis,
    ServerCapabilities,
};

pub use matrix_sdk;
