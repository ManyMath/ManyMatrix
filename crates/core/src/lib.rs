mod client;
mod error;
mod session;
mod types;

#[cfg(not(target_family = "wasm"))]
pub use client::ClientOptions;
pub use client::ManyMatrixClient;
pub use error::Error;
pub use session::StoredSession;
pub use types::{
    CreateRoomOptions, CustomEvent, LastMessage, MessageEvent, PaginatedMessages,
    PaginatedThreadMessages, ReactionEvent, ReceiptEvent, RoomDetails, RoomInvite, RoomSummary,
    RoomVisibility, SasEmoji, SasEmojis, ServerCapabilities, ThreadSummary,
};

pub use matrix_sdk;
