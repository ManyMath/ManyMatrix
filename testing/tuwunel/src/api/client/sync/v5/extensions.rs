mod account_data;
mod e2ee;
mod receipts;
mod to_device;
mod typing;

use std::fmt::Debug;

use futures::{
	FutureExt,
	future::{OptionFuture, join5},
};
use ruma::{
	RoomId,
	api::client::sync::sync_events::v5::{ListId, request::ExtensionRoomConfig, response},
};
use tuwunel_core::{Result, apply, at, extract_variant, utils::BoolExt};
use tuwunel_service::sync::Connection;

use super::{SyncInfo, Window, share_encrypted_room};

#[tracing::instrument(
	name = "extensions",
	level = "debug",
	skip_all,
	fields(
		next_batch = conn.next_batch,
		window = window.len(),
		rooms = conn.rooms.len(),
		subs = conn.subscriptions.len(),
	)
)]
pub(super) async fn handle(
	sync_info: SyncInfo<'_>,
	conn: &Connection,
	window: &Window,
) -> Result<response::Extensions> {
	let SyncInfo { .. } = sync_info;

	let account_data: OptionFuture<_> = conn
		.extensions
		.account_data
		.enabled
		.unwrap_or(false)
		.then(|| account_data::collect(sync_info, conn, window))
		.into();

	let receipts: OptionFuture<_> = conn
		.extensions
		.receipts
		.enabled
		.unwrap_or(false)
		.then(|| receipts::collect(sync_info, conn, window))
		.into();

	let typing: OptionFuture<_> = conn
		.extensions
		.typing
		.enabled
		.unwrap_or(false)
		.then(|| typing::collect(sync_info, conn, window))
		.into();

	let to_device: OptionFuture<_> = conn
		.extensions
		.to_device
		.enabled
		.unwrap_or(false)
		.then(|| to_device::collect(sync_info, conn))
		.into();

	let e2ee: OptionFuture<_> = conn
		.extensions
		.e2ee
		.enabled
		.unwrap_or(false)
		.then(|| e2ee::collect(sync_info, conn))
		.into();

	let (account_data, receipts, typing, to_device, e2ee) =
		join5(account_data, receipts, typing, to_device, e2ee)
			.map(apply!(5, |t: Option<_>| t.unwrap_or(Ok(Default::default()))))
			.await;

	Ok(response::Extensions {
		account_data: account_data?,
		receipts: receipts?,
		typing: typing?,
		to_device: to_device?,
		e2ee: e2ee?,
	})
}

#[tracing::instrument(
	name = "selector",
	level = "trace",
	skip_all,
	fields(?implicit, ?explicit),
)]
fn selector<'a, ListIter, SubsIter>(
	SyncInfo { .. }: SyncInfo<'a>,
	conn: &'a Connection,
	window: &'a Window,
	implicit: Option<ListIter>,
	explicit: Option<SubsIter>,
) -> impl Iterator<Item = &'a RoomId> + Send + Sync + 'a
where
	ListIter: Iterator<Item = &'a ListId> + Clone + Debug + Send + Sync + 'a,
	SubsIter: Iterator<Item = &'a ExtensionRoomConfig> + Clone + Debug + Send + Sync + 'a,
{
	let has_all_subscribed = explicit
		.clone()
		.into_iter()
		.flatten()
		.any(|erc| matches!(erc, ExtensionRoomConfig::AllSubscribed));

	let all_subscribed = has_all_subscribed
		.then(|| conn.subscriptions.keys())
		.into_iter()
		.flatten()
		.map(AsRef::as_ref);

	let rooms_explicit = has_all_subscribed
		.is_false()
		.then(move || {
			explicit
				.into_iter()
				.flatten()
				.filter_map(|erc| extract_variant!(erc, ExtensionRoomConfig::Room))
				.map(AsRef::as_ref)
		})
		.into_iter()
		.flatten();

	let rooms_selected = window
		.iter()
		.filter(move |(_, room)| {
			implicit.as_ref().is_none_or(|lists| {
				lists
					.clone()
					.any(|list| room.lists.contains(list))
			})
		})
		.map(at!(0))
		.map(AsRef::as_ref);

	all_subscribed
		.chain(rooms_explicit)
		.chain(rooms_selected)
}
