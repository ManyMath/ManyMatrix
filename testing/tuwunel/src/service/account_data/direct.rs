use ruma::{
	RoomId, UserId,
	events::{GlobalAccountDataEventType, direct::DirectEventContent},
};
use tuwunel_core::{at, implement, is_equal_to};

#[implement(super::Service)]
pub async fn is_direct(&self, user_id: &UserId, room_id: &RoomId) -> bool {
	self.services
		.account_data
		.get_global(user_id, GlobalAccountDataEventType::Direct)
		.await
		.map(|content: DirectEventContent| content)
		.into_iter()
		.flat_map(DirectEventContent::into_iter)
		.map(at!(1))
		.flat_map(Vec::into_iter)
		.any(is_equal_to!(room_id))
}
