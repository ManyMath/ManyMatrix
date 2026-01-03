use axum::extract::State;
use ruma::{
	api::client::redact::redact_event, events::room::redaction::RoomRedactionEventContent,
};
use tuwunel_core::{Result, matrix::pdu::PduBuilder};

use crate::Ruma;

/// # `PUT /_matrix/client/r0/rooms/{roomId}/redact/{eventId}/{txnId}`
///
/// Tries to send a redaction event into the room.
///
/// - TODO: Handle txn id
pub(crate) async fn redact_event_route(
	State(services): State<crate::State>,
	body: Ruma<redact_event::v3::Request>,
) -> Result<redact_event::v3::Response> {
	let sender_user = body.sender_user();
	let body = &body.body;

	let state_lock = services.state.mutex.lock(&body.room_id).await;

	let event_id = services
		.timeline
		.build_and_append_pdu(
			PduBuilder {
				redacts: Some(body.event_id.clone()),
				..PduBuilder::timeline(&RoomRedactionEventContent {
					redacts: Some(body.event_id.clone()),
					reason: body.reason.clone(),
				})
			},
			sender_user,
			&body.room_id,
			&state_lock,
		)
		.await?;

	drop(state_lock);

	Ok(redact_event::v3::Response { event_id })
}
