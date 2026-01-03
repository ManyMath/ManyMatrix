use futures::{FutureExt, StreamExt};
use ruma::{
	OwnedRoomId, RoomId,
	api::client::sync::sync_events::v5::response,
	events::{AnySyncEphemeralRoomEvent, receipt::SyncReceiptEvent},
	serde::Raw,
};
use tuwunel_core::{
	Result,
	utils::{BoolExt, IterStream, stream::BroadbandExt},
};
use tuwunel_service::{rooms::read_receipt::pack_receipts, sync::Room};

use super::{Connection, SyncInfo, Window, selector};

#[tracing::instrument(name = "receipts", level = "trace", skip_all)]
pub(super) async fn collect(
	sync_info: SyncInfo<'_>,
	conn: &Connection,
	window: &Window,
) -> Result<response::Receipts> {
	let SyncInfo { .. } = sync_info;

	let implicit = conn
		.extensions
		.receipts
		.lists
		.as_deref()
		.map(<[_]>::iter);

	let explicit = conn
		.extensions
		.receipts
		.rooms
		.as_deref()
		.map(<[_]>::iter);

	let rooms = selector(sync_info, conn, window, implicit, explicit)
		.stream()
		.broad_filter_map(|room_id| collect_room(sync_info, conn, window, room_id))
		.collect()
		.await;

	Ok(response::Receipts { rooms })
}

#[tracing::instrument(level = "trace", skip_all, fields(room_id), ret)]
async fn collect_room(
	SyncInfo { services, sender_user, .. }: SyncInfo<'_>,
	conn: &Connection,
	_window: &Window,
	room_id: &RoomId,
) -> Option<(OwnedRoomId, Raw<SyncReceiptEvent>)> {
	let &Room { roomsince, .. } = conn.rooms.get(room_id)?;
	let private_receipt = services
		.read_receipt
		.last_privateread_update(sender_user, room_id)
		.then(async |last_private_update| {
			if last_private_update <= roomsince || last_private_update > conn.next_batch {
				return None;
			}

			services
				.read_receipt
				.private_read_get(room_id, sender_user)
				.map(Some)
				.await
		})
		.map(Option::into_iter)
		.map(Iterator::flatten)
		.map(IterStream::stream)
		.flatten_stream();

	let receipts: Vec<Raw<AnySyncEphemeralRoomEvent>> = services
		.read_receipt
		.readreceipts_since(room_id, roomsince, Some(conn.next_batch))
		.filter_map(async |(read_user, _ts, v)| {
			services
				.users
				.user_is_ignored(read_user, sender_user)
				.await
				.or_some(v)
		})
		.chain(private_receipt)
		.collect()
		.boxed()
		.await;

	receipts
		.is_empty()
		.is_false()
		.then(|| (room_id.to_owned(), pack_receipts(receipts.into_iter())))
}
