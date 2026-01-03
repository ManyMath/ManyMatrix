use futures::TryFutureExt;
use ruma::{
	RoomId, UserId,
	events::{
		RoomAccountDataEventType,
		tag::{TagEvent, TagEventContent, TagInfo, TagName, Tags},
	},
};
use tuwunel_core::{Result, implement};

#[implement(super::Service)]
pub async fn set_room_tag(
	&self,
	user_id: &UserId,
	room_id: &RoomId,
	tag: TagName,
	info: Option<TagInfo>,
) -> Result {
	let mut tags = self
		.get_room_tags(user_id, room_id)
		.await
		.unwrap_or_default();

	tags.insert(tag, info.unwrap_or_default());

	let event = serde_json::to_value(TagEvent { content: TagEventContent { tags } })?;

	self.update(Some(room_id), user_id, RoomAccountDataEventType::Tag, &event)
		.await
}

#[implement(super::Service)]
pub async fn get_room_tags(&self, user_id: &UserId, room_id: &RoomId) -> Result<Tags> {
	self.services
		.account_data
		.get_room(room_id, user_id, RoomAccountDataEventType::Tag)
		.map_ok(|content: TagEventContent| content.tags)
		.await
}
