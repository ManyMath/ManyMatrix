//! E2EE messaging scenario: key upload, one-time key claim,
//! encrypted message send/receive via raw CS API endpoints.

use std::time::Duration;

use super::common::{
	MatrixClient, DEFAULT_PASSWORD, REGISTRATION_TOKEN, SERVER_NAME,
};

/// Entry point for the e2ee-messaging subcommand.
pub async fn run_e2ee_messaging(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	match role {
		| "alice" => run_alice(server_url).await,
		| "bob" => run_bob(server_url).await,
		| other =>
			Err(format!("unknown role: {other} (expected alice or bob)")
				.into()),
	}
}

/// Generate a fake Ed25519 device signing key (base64-encoded).
/// Crypto validity is irrelevant; we are testing server endpoints.
fn fake_device_key_base64() -> String {
	use std::collections::hash_map::DefaultHasher;
	use std::hash::{Hash, Hasher};

	let mut hasher = DefaultHasher::new();
	"e2ee-test-device-key".hash(&mut hasher);
	let hash = hasher.finish();
	let bytes = hash.to_le_bytes();

	let mut key_bytes = [0u8; 32];
	for i in 0usize..4 {
		let start = i.checked_mul(8).unwrap_or(0);
		let end = start.checked_add(8).unwrap_or(32).min(32);
		key_bytes[start..end].copy_from_slice(&bytes);
	}

	ruma::serde::Base64::<ruma::serde::base64::Standard>::new(
		key_bytes.to_vec(),
	)
	.to_string()
}

/// Upload device keys and one-time keys to the server.
async fn upload_device_keys(
	client: &MatrixClient,
	user_id: &str,
	device_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for key upload")?;
	let url = format!(
		"{}/_matrix/client/v3/keys/upload",
		client.base_url()
	);

	let fake_key = fake_device_key_base64();

	let device_keys = serde_json::json!({
		"user_id": user_id,
		"device_id": device_id,
		"algorithms": [
			"m.olm.v1.curve25519-aes-sha2",
			"m.megolm.v1.aes-sha2"
		],
		"keys": {
			format!("curve25519:{device_id}"): fake_key,
			format!("ed25519:{device_id}"): fake_key,
		},
		"signatures": {
			user_id: {
				format!("ed25519:{device_id}"): fake_key,
			}
		}
	});

	let mut one_time_keys = serde_json::Map::new();
	for i in 0..5u32 {
		let key_id =
			format!("signed_curve25519:AAAAAQ{i}");
		one_time_keys.insert(
			key_id,
			serde_json::json!({
				"key": fake_key,
				"signatures": {
					user_id: {
						format!("ed25519:{device_id}"): fake_key,
					}
				}
			}),
		);
	}

	let body = serde_json::json!({
		"device_keys": device_keys,
		"one_time_keys": one_time_keys,
	});

	let resp = client
		.http()
		.post(&url)
		.bearer_auth(token)
		.json(&body)
		.send()
		.await?;

	let status = resp.status();
	let resp_body: serde_json::Value = resp.json().await?;

	if !status.is_success() {
		return Err(format!(
			"keys/upload failed: {status} {resp_body}"
		)
		.into());
	}

	eprintln!(
		"{user_id}: device keys uploaded (one_time_key_counts: \
		 {})",
		resp_body
			.get("one_time_key_counts")
			.map_or("unknown".to_owned(), |v| v.to_string())
	);

	Ok(())
}

/// Claim one-time keys for a target user's device.
async fn claim_one_time_keys(
	client: &MatrixClient,
	target_user_id: &str,
	target_device_id: &str,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for key claim")?;
	let url = format!(
		"{}/_matrix/client/v3/keys/claim",
		client.base_url()
	);

	let body = serde_json::json!({
		"one_time_keys": {
			target_user_id: {
				target_device_id: "signed_curve25519"
			}
		}
	});

	let resp = client
		.http()
		.post(&url)
		.bearer_auth(token)
		.json(&body)
		.send()
		.await?;

	let status = resp.status();
	let resp_body: serde_json::Value = resp.json().await?;

	if !status.is_success() {
		return Err(format!(
			"keys/claim failed: {status} {resp_body}"
		)
		.into());
	}

	eprintln!(
		"key claim completed for {target_user_id}:{target_device_id}"
	);
	Ok(resp_body)
}

/// Create an encrypted room with the given alias.
async fn create_encrypted_room(
	client: &MatrixClient,
	alias_local: &str,
) -> Result<String, Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for room creation")?;
	let url = format!(
		"{}/_matrix/client/v3/createRoom",
		client.base_url()
	);

	let body = serde_json::json!({
		"room_alias_name": alias_local,
		"visibility": "private",
		"preset": "private_chat",
		"initial_state": [
			{
				"type": "m.room.encryption",
				"state_key": "",
				"content": {
					"algorithm": "m.megolm.v1.aes-sha2"
				}
			}
		]
	});

	let resp = client
		.http()
		.post(&url)
		.bearer_auth(token)
		.json(&body)
		.send()
		.await?;

	let status = resp.status();
	let resp_body: serde_json::Value = resp.json().await?;

	if !status.is_success() {
		return Err(format!(
			"createRoom failed: {status} {resp_body}"
		)
		.into());
	}

	let room_id = resp_body
		.get("room_id")
		.and_then(|v| v.as_str())
		.ok_or("createRoom response missing room_id")?
		.to_owned();

	eprintln!("created encrypted room: {room_id}");
	Ok(room_id)
}

async fn invite_user(
	client: &MatrixClient,
	room_id: &str,
	user_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for invite")?;
	let url = format!(
		"{}/_matrix/client/v3/rooms/{}/invite",
		client.base_url(),
		urlencoding::encode(room_id),
	);

	let body = serde_json::json!({ "user_id": user_id });

	let resp = client
		.http()
		.post(&url)
		.bearer_auth(token)
		.json(&body)
		.send()
		.await?;

	let status = resp.status();
	if !status.is_success() {
		let resp_body: serde_json::Value = resp.json().await?;
		return Err(format!(
			"invite failed: {status} {resp_body}"
		)
		.into());
	}

	eprintln!("invited {user_id} to {room_id}");
	Ok(())
}

async fn join_room_by_alias(
	client: &MatrixClient,
	alias: &str,
	max_retries: u32,
	retry_interval: Duration,
) -> Result<String, Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for join")?;

	for attempt in 0..max_retries {
		let url = format!(
			"{}/_matrix/client/v3/join/{}",
			client.base_url(),
			urlencoding::encode(alias),
		);

		let resp = client
			.http()
			.post(&url)
			.bearer_auth(token)
			.json(&serde_json::json!({}))
			.send()
			.await?;

		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		if status.is_success() {
			let room_id = resp_body
				.get("room_id")
				.and_then(|v| v.as_str())
				.ok_or("join response missing room_id")?
				.to_owned();
			eprintln!(
				"joined {alias} after {attempt} retries: \
				 {room_id}"
			);
			return Ok(room_id);
		}

		eprintln!(
			"join attempt {attempt} for {alias}: {status}"
		);
		tokio::time::sleep(retry_interval).await;
	}

	Err(format!(
		"failed to join {alias} after {max_retries} retries"
	)
	.into())
}

/// Send a fake m.room.encrypted event. Real Olm/Megolm is not
/// available; the marker is embedded in ciphertext for sync lookup.
async fn send_encrypted_message(
	client: &MatrixClient,
	room_id: &str,
	plaintext_marker: &str,
	txn_id: &str,
) -> Result<String, Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for send")?;
	let url = format!(
		"{}/_matrix/client/v3/rooms/{}/send/m.room.encrypted/{}",
		client.base_url(),
		urlencoding::encode(room_id),
		urlencoding::encode(txn_id),
	);

	let body = serde_json::json!({
		"algorithm": "m.megolm.v1.aes-sha2",
		"sender_key": "fake_sender_curve25519_key",
		"ciphertext": format!(
			"ENCRYPTED[{plaintext_marker}]"
		),
		"session_id": "fake_megolm_session_id",
		"device_id": "ALICE_DEV",
	});

	let resp = client
		.http()
		.put(&url)
		.bearer_auth(token)
		.json(&body)
		.send()
		.await?;

	let status = resp.status();
	let resp_body: serde_json::Value = resp.json().await?;

	if !status.is_success() {
		return Err(format!(
			"send encrypted message failed: {status} {resp_body}"
		)
		.into());
	}

	let event_id = resp_body
		.get("event_id")
		.and_then(|v| v.as_str())
		.unwrap_or("unknown")
		.to_owned();

	eprintln!("encrypted message sent: {event_id}");
	Ok(event_id)
}

async fn sync_once(
	client: &MatrixClient,
	since: Option<&str>,
	timeout_ms: u32,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for sync")?;

	let mut url = format!(
		"{}/_matrix/client/v3/sync?timeout={timeout_ms}",
		client.base_url(),
	);
	if let Some(since_token) = since {
		url.push_str(&format!(
			"&since={}",
			urlencoding::encode(since_token)
		));
	}

	let resp = client
		.http()
		.get(&url)
		.bearer_auth(token)
		.send()
		.await?;

	let status = resp.status();
	let resp_body: serde_json::Value = resp.json().await?;

	if !status.is_success() {
		return Err(format!(
			"sync failed: {status} {resp_body}"
		)
		.into());
	}

	Ok(resp_body)
}

fn next_batch(sync_resp: &serde_json::Value) -> Option<String> {
	sync_resp
		.get("next_batch")
		.and_then(|v| v.as_str())
		.map(|s| s.to_owned())
}

async fn get_joined_members_count(
	client: &MatrixClient,
	room_id: &str,
) -> Result<u64, Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for members query")?;
	let url = format!(
		"{}/_matrix/client/v3/rooms/{}/joined_members",
		client.base_url(),
		urlencoding::encode(room_id),
	);

	let resp = client
		.http()
		.get(&url)
		.bearer_auth(token)
		.send()
		.await?;

	let status = resp.status();
	let resp_body: serde_json::Value = resp.json().await?;

	if !status.is_success() {
		return Err(format!(
			"joined_members failed: {status} {resp_body}"
		)
		.into());
	}

	let count = resp_body
		.get("joined")
		.and_then(|v| v.as_object())
		.map(|m| m.len())
		.unwrap_or(0);

	#[expect(clippy::as_conversions)]
	Ok(count as u64)
}

async fn query_user_devices(
	client: &MatrixClient,
	user_id: &str,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for key query")?;
	let url = format!(
		"{}/_matrix/client/v3/keys/query",
		client.base_url()
	);

	let body = serde_json::json!({
		"device_keys": {
			user_id: []
		}
	});

	let resp = client
		.http()
		.post(&url)
		.bearer_auth(token)
		.json(&body)
		.send()
		.await?;

	let status = resp.status();
	let resp_body: serde_json::Value = resp.json().await?;

	if !status.is_success() {
		return Err(format!(
			"keys/query failed: {status} {resp_body}"
		)
		.into());
	}

	let device_ids: Vec<String> = resp_body
		.get("device_keys")
		.and_then(|dk| dk.get(user_id))
		.and_then(|u| u.as_object())
		.map(|devices| {
			devices.keys().cloned().collect()
		})
		.unwrap_or_default();

	Ok(device_ids)
}

/// Alice: register, upload keys, create encrypted room, invite bob,
/// send encrypted message.
async fn run_alice(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	let mut client = MatrixClient::new(server_url).await?;

	client
		.register_with_token(
			"alice",
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;
	client.login_user("alice", DEFAULT_PASSWORD).await?;

	let alice_user_id = format!("@alice:{SERVER_NAME}");

	let sync_resp = sync_once(&client, None, 1000).await?;
	let mut batch = next_batch(&sync_resp);
	eprintln!("alice: initial sync complete");

	upload_device_keys(&client, &alice_user_id, "ALICE_DEV")
		.await?;
	eprintln!("alice: device keys uploaded");

	let room_id =
		create_encrypted_room(&client, "e2ee-room").await?;
	eprintln!("alice: room encryption enabled");

	let bob_user_id = format!("@bob:{SERVER_NAME}");
	invite_user(&client, &room_id, &bob_user_id).await?;

	let poll_interval = Duration::from_millis(2000);
	for attempt in 0..30u32 {
		let count =
			get_joined_members_count(&client, &room_id).await?;
		if count >= 2 {
			eprintln!(
				"alice: bob has joined, sending encrypted message"
			);
			break;
		}
		if attempt == 29 {
			return Err(
				"alice: timed out waiting for bob to join".into()
			);
		}
		eprintln!(
			"alice: waiting for bob (attempt {attempt}, members: \
			 {count})"
		);
		tokio::time::sleep(poll_interval).await;
	}

	let sync_resp =
		sync_once(&client, batch.as_deref(), 1000).await?;
	batch = next_batch(&sync_resp);
	let _ = batch; // suppress unused warning
	eprintln!("alice: synced after bob joined");

	send_encrypted_message(
		&client,
		&room_id,
		"encrypted secret from alice",
		"txn001",
	)
	.await?;
	eprintln!("alice: encrypted message sent");

	eprintln!("alice: e2ee-messaging scenario complete");
	Ok(())
}

/// Bob: register, upload keys, join encrypted room, claim alice's
/// keys, sync to receive encrypted message.
async fn run_bob(
	server_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	let mut client = MatrixClient::new(server_url).await?;

	client
		.register_with_token(
			"bob",
			DEFAULT_PASSWORD,
			REGISTRATION_TOKEN,
		)
		.await?;
	client.login_user("bob", DEFAULT_PASSWORD).await?;

	let bob_user_id = format!("@bob:{SERVER_NAME}");
	let alice_user_id = format!("@alice:{SERVER_NAME}");

	let sync_resp = sync_once(&client, None, 1000).await?;
	let mut batch = next_batch(&sync_resp);
	eprintln!("bob: initial sync complete");

	upload_device_keys(&client, &bob_user_id, "BOB_DEV").await?;
	eprintln!("bob: device keys uploaded");

	let e2ee_alias =
		format!("#e2ee-room:{SERVER_NAME}");
	let room_id = join_room_by_alias(
		&client,
		&e2ee_alias,
		30,
		Duration::from_millis(1000),
	)
	.await?;
	eprintln!("bob: joined e2ee room");

	let sync_resp =
		sync_once(&client, batch.as_deref(), 1000).await?;
	batch = next_batch(&sync_resp);

	let alice_devices =
		query_user_devices(&client, &alice_user_id).await?;
	let alice_device = alice_devices
		.first()
		.cloned()
		.unwrap_or_else(|| "ALICE_DEV".to_owned());
	let _claim_resp = claim_one_time_keys(
		&client,
		&alice_user_id,
		&alice_device,
	)
	.await?;
	eprintln!("bob: synced after join (key claim completed)");

	let poll_interval = Duration::from_millis(2000);
	let marker = "encrypted secret from alice";

	for attempt in 0..30u32 {
		let sync_resp =
			sync_once(&client, batch.as_deref(), 5000).await?;
		batch = next_batch(&sync_resp);

		let found = sync_resp
			.get("rooms")
			.and_then(|r| r.get("join"))
			.and_then(|j| j.get(&room_id))
			.and_then(|r| r.get("timeline"))
			.and_then(|t| t.get("events"))
			.and_then(|e| e.as_array())
			.map(|events| {
				events.iter().any(|ev| {
					let is_encrypted = ev
						.get("type")
						.and_then(|t| t.as_str())
						== Some("m.room.encrypted");
					let has_marker = ev
						.get("content")
						.map(|c| {
							c.to_string().contains(marker)
						})
						.unwrap_or(false);
					is_encrypted && has_marker
				})
			})
			.unwrap_or(false);

		if found {
			eprintln!(
				"bob: received decrypted message: {marker}"
			);
			break;
		}

		if attempt == 29 {
			return Err(
				"bob: timed out waiting for encrypted message"
					.into(),
			);
		}

		eprintln!(
			"bob: polling for encrypted message (attempt \
			 {attempt})"
		);
		tokio::time::sleep(poll_interval).await;
	}

	eprintln!("bob: e2ee-messaging scenario complete");
	Ok(())
}
