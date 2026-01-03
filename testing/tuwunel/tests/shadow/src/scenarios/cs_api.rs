//! CS API scenario: register, login, create room, send message,
//! join, sync.
//!
//! Two-client flow with alice (room creator, message sender) and
//! bob (joiner, message receiver) running on separate Shadow hosts.

use super::common::{
	create_sdk_client, DEFAULT_PASSWORD, REGISTRATION_TOKEN,
};

/// Room alias local part used by alice when creating the test room.
const ROOM_ALIAS: &str = "test-room";

/// Full room alias including server name.
const ROOM_ALIAS_FULL: &str = "#test-room:tuwunel-server";

/// Entry point dispatching to alice or bob role.
pub async fn run_cs_api(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	match role {
		| "alice" => run_alice(server_url).await,
		| "bob" => run_bob(server_url).await,
		| other =>
			Err(format!("Unknown role: {other}").into()),
	}
}

/// Alice flow: register, login, create room with alias, send
/// message.
async fn run_alice(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("alice: starting cs-api scenario");

	let mut client = create_sdk_client(server_url).await?;

	client
		.register_with_token(
			"alice",
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;

	client.login_user("alice", DEFAULT_PASSWORD).await?;

	let room_id =
		client.create_room(Some(ROOM_ALIAS)).await?;
	eprintln!("alice: created room {room_id} with alias {ROOM_ALIAS_FULL}");

	let event_id = client
		.send_text_message(&room_id, "Hello from Alice")
		.await?;
	eprintln!("alice: sent message, event_id={event_id}");

	eprintln!("alice: cs-api scenario complete");
	Ok(())
}

/// Bob flow: register, login, join room by alias with retry, sync,
/// verify message.
async fn run_bob(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("bob: starting cs-api scenario");

	let mut client = create_sdk_client(server_url).await?;

	client
		.register_with_token(
			"bob",
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;

	client.login_user("bob", DEFAULT_PASSWORD).await?;

	// Room alias may not resolve immediately; retry.
	let room_id = client
		.join_room_with_retry(ROOM_ALIAS_FULL, 30, 1000)
		.await?;
	eprintln!("bob: joined room {room_id}");

	let sync_response = client.sync(None).await?;

	let message_found = check_sync_for_message(
		&sync_response,
		&room_id,
		"Hello from Alice",
	);

	if message_found {
		eprintln!(
			"bob: received message: Hello from Alice"
		);
	} else {
		// Initial sync may not include the message timeline
		let next_batch = sync_response
			.get("next_batch")
			.and_then(|v| v.as_str());

		if let Some(token) = next_batch {
			eprintln!(
				"bob: message not in initial sync, \
				 trying incremental sync"
			);
			let sync2 =
				client.sync(Some(token)).await?;
			let found2 = check_sync_for_message(
				&sync2,
				&room_id,
				"Hello from Alice",
			);
			if found2 {
				eprintln!(
					"bob: received message: \
					 Hello from Alice"
				);
			} else {
				return Err(
					"bob: did not receive 'Hello from \
					 Alice' message after sync"
						.into(),
				);
			}
		} else {
			return Err(
				"bob: did not receive 'Hello from \
				 Alice' message in sync response"
					.into(),
			);
		}
	}

	eprintln!("bob: cs-api scenario complete");
	Ok(())
}

/// Search a sync response for a text message in a room's timeline.
fn check_sync_for_message(
	sync: &serde_json::Value,
	room_id: &str,
	text: &str,
) -> bool {
	let rooms = match sync.get("rooms") {
		| Some(r) => r,
		| None => return false,
	};

	let join = match rooms.get("join") {
		| Some(j) => j,
		| None => return false,
	};

	let room = match join.get(room_id) {
		| Some(r) => r,
		| None => return false,
	};

	let timeline = match room.get("timeline") {
		| Some(t) => t,
		| None => return false,
	};

	let events = match timeline.get("events") {
		| Some(serde_json::Value::Array(arr)) => arr,
		| _ => return false,
	};

	for event in events {
		let content = match event.get("content") {
			| Some(c) => c,
			| None => continue,
		};

		let body = match content.get("body") {
			| Some(serde_json::Value::String(s)) => s,
			| _ => continue,
		};

		if body.contains(text) {
			return true;
		}
	}

	false
}
