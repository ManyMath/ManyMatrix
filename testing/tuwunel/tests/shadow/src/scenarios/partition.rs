//! Partition scenario: federation survives server2 downtime.
//!
//! Three-role flow: creator sets up a federated room between server1
//! and server2, survivor operates on server1 while server2 is down,
//! verifier confirms data persisted after server2 restarts.

use super::{
	common::{
		create_sdk_client, DEFAULT_PASSWORD, REGISTRATION_TOKEN,
	},
	federation::check_sync_for_message,
};

/// Creator username on server1.
const PART_USERNAME_CREATOR: &str = "part-creator";

/// Joiner username on server2.
const PART_USERNAME_JOINER: &str = "part-joiner";

/// Room alias local part for the partition test room.
const PART_ROOM_ALIAS: &str = "part-test";

/// Message sent by creator during initial setup.
const PART_MESSAGE: &str = "partition test message";

/// Message sent by survivor while server2 is down.
const SURVIVOR_MESSAGE: &str =
	"survivor message during partition";

/// Entry point for the partition subcommand.
pub async fn run_partition(
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
	eprintln!("creator: starting partition scenario");

	let mut client = create_sdk_client(server_url).await?;
	client
		.register_with_token(
			PART_USERNAME_CREATOR,
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;
	eprintln!("creator: registered {PART_USERNAME_CREATOR}");

	client
		.login_user(PART_USERNAME_CREATOR, DEFAULT_PASSWORD)
		.await?;
	eprintln!("creator: logged in");

	let room_id =
		client.create_room(Some(PART_ROOM_ALIAS)).await?;
	eprintln!(
		"creator: created room {room_id} with alias \
		 #{PART_ROOM_ALIAS}"
	);

	let event_id = client
		.send_text_message(&room_id, PART_MESSAGE)
		.await?;
	eprintln!("creator: sent message, event_id={event_id}");

	let mut remote_client =
		create_sdk_client(remote_url).await?;
	remote_client
		.register_with_token(
			PART_USERNAME_JOINER,
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;
	eprintln!(
		"creator: registered {PART_USERNAME_JOINER} on server2"
	);

	remote_client
		.login_user(PART_USERNAME_JOINER, DEFAULT_PASSWORD)
		.await?;
	eprintln!("creator: logged in joiner on server2");

	let alias =
		format!("#{}:{}", PART_ROOM_ALIAS, "server1");
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
		PART_MESSAGE,
	);
	if !found {
		// Try incremental sync
		let next_batch = sync_response
			.get("next_batch")
			.and_then(|v| v.as_str());
		if let Some(token) = next_batch {
			let sync2 =
				remote_client.sync(Some(token)).await?;
			let found2 = check_sync_for_message(
				&sync2,
				&joined_room_id,
				PART_MESSAGE,
			);
			if !found2 {
				return Err(
					"creator: joiner did not receive \
					 partition message via federation"
						.into(),
				);
			}
		} else {
			return Err(
				"creator: joiner did not receive partition \
				 message in sync"
					.into(),
			);
		}
	}

	eprintln!(
		"creator: partition setup complete, room={room_id}"
	);
	Ok(())
}

/// Survivor: login on server1, send message while server2 is down.
async fn run_survivor(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("survivor: starting partition scenario");

	let mut client = create_sdk_client(server_url).await?;
	client
		.login_user(PART_USERNAME_CREATOR, DEFAULT_PASSWORD)
		.await?;
	eprintln!("survivor: logged in as {PART_USERNAME_CREATOR}");

	let sync_response = client.sync(None).await?;
	let room_id = find_first_joined_room(&sync_response)?;
	eprintln!("survivor: found room {room_id}");

	let event_id = client
		.send_text_message(&room_id, SURVIVOR_MESSAGE)
		.await?;
	eprintln!(
		"survivor: sent message during partition, \
		 event_id={event_id}"
	);

	eprintln!("survivor: sent message during partition");
	Ok(())
}

/// Verifier: login on server2 after restart, verify data persisted.
async fn run_verifier(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	eprintln!("verifier: starting partition scenario");

	let mut client = create_sdk_client(server_url).await?;
	client
		.login_user(PART_USERNAME_JOINER, DEFAULT_PASSWORD)
		.await?;
	eprintln!(
		"verifier: logged in as {PART_USERNAME_JOINER}"
	);

	let sync_response = client.sync(None).await?;
	let mut found = false;

	if let Some(rooms) = sync_response.get("rooms") {
		if let Some(join) = rooms.get("join") {
			if let Some(obj) = join.as_object() {
				for room_id in obj.keys() {
					if check_sync_for_message(
						&sync_response,
						room_id,
						PART_MESSAGE,
					) {
						eprintln!(
							"verifier: found message \
							 \"{PART_MESSAGE}\" in \
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
		let next_batch = sync_response
			.get("next_batch")
			.and_then(|v| v.as_str());
		if let Some(token) = next_batch {
			let sync2 = client.sync(Some(token)).await?;
			if let Some(rooms) = sync2.get("rooms") {
				if let Some(join) = rooms.get("join") {
					if let Some(obj) = join.as_object() {
						for room_id in obj.keys() {
							if check_sync_for_message(
								&sync2, room_id,
								PART_MESSAGE,
							) {
								eprintln!(
									"verifier: found \
									 message \
									 \"{PART_MESSAGE}\" \
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
				"verifier: did not find partition message \
				 after server2 restart"
					.into(),
			);
		}
	}

	eprintln!("verifier: partition recovery verified");
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
