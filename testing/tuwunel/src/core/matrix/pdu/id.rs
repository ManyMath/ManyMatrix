use super::{Count, RawId, ShortRoomId};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Id {
	pub shortroomid: ShortRoomId,
	pub count: Count,
}

impl From<RawId> for Id {
	#[inline]
	fn from(raw: RawId) -> Self {
		Self {
			shortroomid: u64::from_be_bytes(raw.shortroomid()),
			count: Count::from_unsigned(u64::from_be_bytes(raw.count())),
		}
	}
}
