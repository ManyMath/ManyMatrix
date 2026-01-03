//! Federation scenario: two tuwunel instances on separate Shadow hosts
//! exchange messages via Server-Server API.

use std::time::Duration;

use super::common::{MatrixClient, REGISTRATION_TOKEN};

/// Run the federation scenario for a given role.
pub async fn run_federation(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("Federation scenario: role={role} server={server_url}");

	match role {
		| "creator" => run_creator(server_url).await,
		| "joiner" => run_joiner(server_url).await,
		| other =>
			Err(format!("Unknown federation role: {other}").into()),
	}
}

/// Creator: register, create room, send message, verify joiner's
/// reply.
async fn run_creator(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	let mut client = MatrixClient::new(server_url).await?;

	client
		.register_with_token(
			"fed_creator",
			"creator_pass",
			REGISTRATION_TOKEN,
		)
		.await?;

	let room_id = client
		.create_room(Some("federation_test"))
		.await?;
	eprintln!("Creator: room created {room_id}");

	let event_id = client
		.send_text_message(&room_id, "hello from creator via federation")
		.await?;
	eprintln!("Creator: sent message {event_id}");

	let mut since: Option<String> = None;
	for attempt in 0..60_u32 {
		let sync_resp = client.sync(since.as_deref()).await?;

		if let Some(token) =
			sync_resp.get("next_batch").and_then(|v| v.as_str())
		{
			since = Some(token.to_owned());
		}

		if let Some(rooms) = sync_resp
			.get("rooms")
			.and_then(|r| r.get("join"))
			.and_then(|j| j.get(&room_id))
			.and_then(|r| r.get("timeline"))
			.and_then(|t| t.get("events"))
			.and_then(|e| e.as_array())
		{
			for event in rooms {
				if let Some(body) = event
					.get("content")
					.and_then(|c| c.get("body"))
					.and_then(|b| b.as_str())
				{
					if body.contains("hello from joiner") {
						eprintln!(
							"Creator: received joiner's reply \
							 after {attempt} sync rounds"
						);
						return Ok(());
					}
				}
			}
		}

		tokio::time::sleep(Duration::from_millis(500)).await;
	}

	Err("Creator: timed out waiting for joiner's reply".into())
}

/// Joiner: register on server B, join federated room, send reply,
/// verify creator's message.
async fn run_joiner(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	let mut client = MatrixClient::new(server_url).await?;

	client
		.register_with_token(
			"fed_joiner",
			"joiner_pass",
			REGISTRATION_TOKEN,
		)
		.await?;

	// Retry: federation key exchange may take time.
	let room_id = client
		.join_room_with_retry(
			"#federation_test:server-a",
			30,
			1000,
		)
		.await?;
	eprintln!("Joiner: joined room {room_id}");

	let event_id = client
		.send_text_message(&room_id, "hello from joiner via federation")
		.await?;
	eprintln!("Joiner: sent reply {event_id}");

	let mut since: Option<String> = None;
	for attempt in 0..30_u32 {
		let sync_resp = client.sync(since.as_deref()).await?;

		if let Some(token) =
			sync_resp.get("next_batch").and_then(|v| v.as_str())
		{
			since = Some(token.to_owned());
		}

		if let Some(rooms) = sync_resp
			.get("rooms")
			.and_then(|r| r.get("join"))
			.and_then(|j| j.get(&room_id))
			.and_then(|r| r.get("timeline"))
			.and_then(|t| t.get("events"))
			.and_then(|e| e.as_array())
		{
			for event in rooms {
				if let Some(body) = event
					.get("content")
					.and_then(|c| c.get("body"))
					.and_then(|b| b.as_str())
				{
					if body.contains("hello from creator") {
						eprintln!(
							"Joiner: received creator's message \
							 after {attempt} sync rounds"
						);
						return Ok(());
					}
				}
			}
		}

		tokio::time::sleep(Duration::from_millis(500)).await;
	}

	Err("Joiner: timed out waiting for creator's message".into())
}

pub fn check_sync_for_message(
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
