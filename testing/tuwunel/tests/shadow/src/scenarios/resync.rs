//! Re-sync scenario: federation catch-up after server downtime.
//!
//! Three-role flow: creator sets up a federated room between server1
//! and server2, survivor sends a message while server2 is offline,
//! verifier confirms the missed message is received after server2
//! restarts.

use super::{
	common::{
		create_sdk_client, DEFAULT_PASSWORD, REGISTRATION_TOKEN,
	},
	federation::check_sync_for_message,
};

/// Creator username on server1.
const RESYNC_USERNAME_CREATOR: &str = "resync-creator";

/// Joiner username on server2.
const RESYNC_USERNAME_JOINER: &str = "resync-joiner";

/// Room alias local part for the resync test room.
const RESYNC_ROOM_ALIAS: &str = "resync-test";

/// Message sent by creator during initial setup.
const RESYNC_SETUP_MESSAGE: &str = "resync setup message";

/// Message sent while server2 is offline -- must be received after
/// restart.
const RESYNC_MISSED_MESSAGE: &str =
	"missed during downtime";

/// Entry point for the resync subcommand.
pub async fn run_resync(
	server_url: &str,
	role: &str,
	remote_server: Option<&str>,
	remote_url: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
	match role {
		| "creator" => run_creator(
			server_url,
			remote_server.unwrap_or("server2"),
			remote_url
				.unwrap_or("http://server2:8448"),
		)
		.await,
		| "survivor" => run_survivor(server_url).await,
		| "verifier" => run_verifier(server_url).await,
		| other =>
			Err(format!("Unknown role: {other}").into()),
	}
}

/// Creator: set up federated room between server1 and server2.
async fn run_creator(
	server_url: &str,
	_remote_server: &str,
	remote_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("creator: starting resync scenario");

	let mut client = create_sdk_client(server_url).await?;
	client
		.register_with_token(
			RESYNC_USERNAME_CREATOR,
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;
	eprintln!(
		"creator: registered {RESYNC_USERNAME_CREATOR}"
	);

	client
		.login_user(RESYNC_USERNAME_CREATOR, DEFAULT_PASSWORD)
		.await?;
	eprintln!("creator: logged in");

	let room_id =
		client.create_room(Some(RESYNC_ROOM_ALIAS)).await?;
	eprintln!(
		"creator: created room {room_id} with alias \
		 #{RESYNC_ROOM_ALIAS}"
	);

	let event_id = client
		.send_text_message(&room_id, RESYNC_SETUP_MESSAGE)
		.await?;
	eprintln!(
		"creator: sent setup message, event_id={event_id}"
	);

	let mut remote_client =
		create_sdk_client(remote_url).await?;
	remote_client
		.register_with_token(
			RESYNC_USERNAME_JOINER,
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;
	eprintln!(
		"creator: registered {RESYNC_USERNAME_JOINER} on \
		 server2"
	);

	remote_client
		.login_user(
			RESYNC_USERNAME_JOINER,
			DEFAULT_PASSWORD,
		)
		.await?;
	eprintln!("creator: logged in joiner on server2");

	let alias =
		format!("#{}:{}", RESYNC_ROOM_ALIAS, "server1");
	let joined_room_id = remote_client
		.join_room_with_retry(&alias, 60, 2000)
		.await?;
	eprintln!(
		"creator: joiner joined room {joined_room_id} via \
		 {alias}"
	);

	let sync_response = remote_client.sync(None).await?;
	let found = check_sync_for_message(
		&sync_response,
		&joined_room_id,
		RESYNC_SETUP_MESSAGE,
	);
	if !found {
		let next_batch = sync_response
			.get("next_batch")
			.and_then(|v| v.as_str());
		if let Some(token) = next_batch {
			let sync2 =
				remote_client.sync(Some(token)).await?;
			let found2 = check_sync_for_message(
				&sync2,
				&joined_room_id,
				RESYNC_SETUP_MESSAGE,
			);
			if !found2 {
				return Err(
					"creator: joiner did not receive \
					 setup message via federation"
						.into(),
				);
			}
		} else {
			return Err(
				"creator: joiner did not receive setup \
				 message in sync"
					.into(),
			);
		}
	}

	eprintln!(
		"creator: resync setup complete, room={room_id}"
	);
	Ok(())
}

/// Survivor: login on server1, send message while server2 is
/// offline.
async fn run_survivor(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("survivor: starting resync scenario");

	let mut client = create_sdk_client(server_url).await?;
	client
		.login_user(
			RESYNC_USERNAME_CREATOR,
			DEFAULT_PASSWORD,
		)
		.await?;
	eprintln!(
		"survivor: logged in as {RESYNC_USERNAME_CREATOR}"
	);

	let sync_response = client.sync(None).await?;
	let room_id = find_first_joined_room(&sync_response)?;
	eprintln!("survivor: found room {room_id}");

	let event_id = client
		.send_text_message(&room_id, RESYNC_MISSED_MESSAGE)
		.await?;
	eprintln!(
		"survivor: sent missed message, event_id={event_id}"
	);

	eprintln!(
		"survivor: sent missed message during server2 \
		 downtime"
	);
	Ok(())
}

/// Verifier: login on server2 after restart, confirm missed message
/// arrived via federation catch-up.
async fn run_verifier(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("verifier: starting resync scenario");

	let mut client = create_sdk_client(server_url).await?;
	client
		.login_user(
			RESYNC_USERNAME_JOINER,
			DEFAULT_PASSWORD,
		)
		.await?;
	eprintln!(
		"verifier: logged in as {RESYNC_USERNAME_JOINER}"
	);

	let mut found = false;
	for attempt in 0..3 {
		let sync_response = client.sync(None).await?;

		if let Some(rooms) = sync_response.get("rooms") {
			if let Some(join) = rooms.get("join") {
				if let Some(obj) = join.as_object() {
					for room_id in obj.keys() {
						if check_sync_for_message(
							&sync_response,
							room_id,
							RESYNC_MISSED_MESSAGE,
						) {
							eprintln!(
								"verifier: found \
								 missed message \
								 \"{RESYNC_MISSED_MESSAGE}\" \
								 in room {room_id} \
								 (attempt {attempt})"
							);
							found = true;
							break;
						}
					}
				}
			}
		}

		if found {
			break;
		}

		eprintln!(
			"verifier: missed message not found in sync \
			 attempt {attempt}, retrying"
		);
		tokio::time::sleep(std::time::Duration::from_secs(
			5,
		))
		.await;
	}

	if !found {
		return Err(
			"verifier: did not receive missed message \
			 after server2 restart"
				.into(),
		);
	}

	eprintln!(
		"verifier: re-sync verified, missed message received"
	);
	Ok(())
}

/// Find the first joined room ID from a sync response.
fn find_first_joined_room(
	sync: &serde_json::Value,
) -> Result<String, Box<dyn std::error::Error>> {
	let rooms = sync
		.get("rooms")
		.ok_or("sync response missing 'rooms'")?;
	let join = rooms
		.get("join")
		.ok_or("sync response missing 'rooms.join'")?;
	let obj = join
		.as_object()
		.ok_or("rooms.join is not an object")?;
	let room_id = obj
		.keys()
		.next()
		.ok_or("no joined rooms found")?
		.to_owned();

	Ok(room_id)
}
