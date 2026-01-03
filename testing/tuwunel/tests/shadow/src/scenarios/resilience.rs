//! Resilience scenario: server restart data persistence.
//!
//! Single-server flow with writer and verifier roles. Writer
//! registers a user, creates a room, and sends a message before the
//! server is SIGTERM'd. Verifier logs in after the server restarts
//! on the same database and confirms all data persisted via /sync.

use super::{
	common::{
		create_sdk_client, DEFAULT_PASSWORD, REGISTRATION_TOKEN,
	},
	federation::check_sync_for_message,
};

/// Username used by both writer and verifier roles.
const RES_USERNAME: &str = "res-user";

/// Message sent by writer for verifier to confirm after restart.
const RES_MESSAGE: &str = "pre-restart persistence test";

/// Room alias local part for the resilience test room.
const ROOM_ALIAS_LOCAL: &str = "res-test";

/// Entry point for the resilience subcommand.
pub async fn run_resilience(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	match role {
		| "writer" => run_writer(server_url).await,
		| "verifier" => run_verifier(server_url).await,
		| other =>
			Err(format!("Unknown role: {other}").into()),
	}
}

/// Writer: register, login, create room, send message before
/// SIGTERM.
async fn run_writer(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("writer: starting resilience scenario");

	let mut client = create_sdk_client(server_url).await?;

	client
		.register_with_token(
			RES_USERNAME,
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;
	eprintln!("writer: registered {RES_USERNAME}");

	client
		.login_user(RES_USERNAME, DEFAULT_PASSWORD)
		.await?;
	eprintln!("writer: logged in");

	let room_id =
		client.create_room(Some(ROOM_ALIAS_LOCAL)).await?;
	eprintln!(
		"writer: created room {room_id} with alias \
		 #{ROOM_ALIAS_LOCAL}"
	);

	let event_id =
		client.send_text_message(&room_id, RES_MESSAGE).await?;
	eprintln!("writer: sent message, event_id={event_id}");

	eprintln!(
		"writer: resilience write complete, room={room_id}"
	);
	Ok(())
}

/// Verifier: login after restart, sync, confirm message persisted.
async fn run_verifier(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("verifier: starting resilience scenario");

	let mut client = create_sdk_client(server_url).await?;

	// Login only; user was created before restart
	client
		.login_user(RES_USERNAME, DEFAULT_PASSWORD)
		.await?;
	eprintln!("verifier: logged in as {RES_USERNAME}");

	let sync_response = client.sync(None).await?;

	let mut found = false;
	if let Some(rooms) = sync_response.get("rooms") {
		if let Some(join) = rooms.get("join") {
			if let Some(obj) = join.as_object() {
				for room_id in obj.keys() {
					if check_sync_for_message(
						&sync_response,
						room_id,
						RES_MESSAGE,
					) {
						eprintln!(
							"verifier: found message \
							 \"{RES_MESSAGE}\" in \
							 room {room_id}"
						);
						found = true;
						break;
					}
				}
			}
		}
	}

	if !found {
		// Try incremental sync
		let next_batch = sync_response
			.get("next_batch")
			.and_then(|v| v.as_str());

		if let Some(token) = next_batch {
			eprintln!(
				"verifier: message not in initial sync, \
				 trying incremental sync"
			);
			let sync2 = client.sync(Some(token)).await?;

			if let Some(rooms) = sync2.get("rooms") {
				if let Some(join) = rooms.get("join") {
					if let Some(obj) = join.as_object() {
						for room_id in obj.keys() {
							if check_sync_for_message(
								&sync2, room_id,
								RES_MESSAGE,
							) {
								eprintln!(
									"verifier: found \
									 message \
									 \"{RES_MESSAGE}\" \
									 in room {room_id} \
									 (incremental)"
								);
								found = true;
								break;
							}
						}
					}
				}
			}
		}

		if !found {
			return Err(
				"verifier: did not find persisted message \
				 after restart"
					.into(),
			);
		}
	}

	eprintln!("verifier: data persisted after restart");
	Ok(())
}
