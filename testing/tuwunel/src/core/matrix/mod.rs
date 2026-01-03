//! Core Matrix Library

pub mod event;
pub mod pdu;
pub mod room_version;
pub mod state_res;

pub use event::{Event, StateKey, TypeExt as EventTypeExt, TypeStateKey, state_key};
pub use pdu::{EventHash, Pdu, PduBuilder, PduCount, PduEvent, PduId, RawPduId};
pub use room_version::{RoomVersion, RoomVersionRules};
pub use state_res::{StateMap, events};

pub type ShortStateKey = ShortId;
pub type ShortEventId = ShortId;
pub type ShortRoomId = ShortId;
pub type ShortId = u64;
