use ruma::{RoomVersionId, events::room::create::RoomCreateEventContent};
pub use ruma::{RoomVersionId as RoomVersion, room_version_rules::RoomVersionRules};

use crate::{Result, err, matrix::Event};

pub fn rules(room_version_id: &RoomVersionId) -> Result<RoomVersionRules> {
	room_version_id.rules().ok_or_else(|| {
		err!(Request(UnsupportedRoomVersion(
			"Unknown or unsupported room version {room_version_id:?}.",
		)))
	})
}

pub fn from_create_event<Pdu: Event>(create_event: &Pdu) -> Result<RoomVersionId> {
	let content: RoomCreateEventContent = create_event.get_content()?;
	Ok(from_create_content(&content).clone())
}

#[inline]
#[must_use]
pub fn from_create_content(content: &RoomCreateEventContent) -> &RoomVersionId {
	&content.room_version
}
