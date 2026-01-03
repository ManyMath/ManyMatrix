//! SAS verification scenario: exercises to-device message routing for
//! the full SAS key verification protocol via raw CS API endpoints.

use std::time::Duration;

use super::common::{
	MatrixClient, DEFAULT_PASSWORD, REGISTRATION_TOKEN, SERVER_NAME,
};

/// Entry point for the sas-verify subcommand.
pub async fn run_sas_verify(
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
/// Crypto validity is irrelevant; we are testing message routing.
fn fake_device_key_base64() -> String {
	use std::collections::hash_map::DefaultHasher;
	use std::hash::{Hash, Hasher};

	let mut hasher = DefaultHasher::new();
	"sas-verify-test-device-key".hash(&mut hasher);
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
		let key_id = format!("signed_curve25519:AAAAAQ{i}");
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

/// Send a to-device message.
async fn send_to_device(
	client: &MatrixClient,
	event_type: &str,
	txn_id: &str,
	messages: &serde_json::Value,
) -> Result<(), Box<dyn std::error::Error>> {
	let token = client
		.access_token()
		.ok_or("not authenticated for sendToDevice")?;

	let url = format!(
		"{}/_matrix/client/v3/sendToDevice/{}/{}",
		client.base_url(),
		urlencoding::encode(event_type),
		urlencoding::encode(txn_id),
	);

	let body = serde_json::json!({ "messages": messages });

	let resp = client
		.http()
		.put(&url)
		.bearer_auth(token)
		.json(&body)
		.send()
		.await?;

	let status = resp.status();
	if !status.is_success() {
		let resp_body: serde_json::Value = resp.json().await?;
		return Err(format!(
			"sendToDevice {event_type} failed: {status} \
			 {resp_body}"
		)
		.into());
	}

	eprintln!("sent to-device: {event_type} (txn={txn_id})");
	Ok(())
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
		return Err(
			format!("sync failed: {status} {resp_body}").into()
		);
	}

	Ok(resp_body)
}

fn next_batch(sync_resp: &serde_json::Value) -> Option<String> {
	sync_resp
		.get("next_batch")
		.and_then(|v| v.as_str())
		.map(|s| s.to_owned())
}

fn extract_to_device_events(
	sync_resp: &serde_json::Value,
	event_type: &str,
) -> Vec<serde_json::Value> {
	sync_resp
		.get("to_device")
		.and_then(|td| td.get("events"))
		.and_then(|e| e.as_array())
		.map(|events| {
			events
				.iter()
				.filter(|ev| {
					ev.get("type").and_then(|t| t.as_str())
						== Some(event_type)
				})
				.cloned()
				.collect()
		})
		.unwrap_or_default()
}

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

/// All verification messages in a single flow share this transaction
/// ID.
const VERIFICATION_TXN_ID: &str = "sas_verify_txn_001";

/// Alice: register, upload keys, create encrypted room, invite bob,
/// drive SAS verification protocol to completion.
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
	let bob_user_id = format!("@bob:{SERVER_NAME}");

	let sync_resp = sync_once(&client, None, 1000).await?;
	let mut batch = next_batch(&sync_resp);
	eprintln!("alice: initial sync complete");

	upload_device_keys(&client, &alice_user_id, "ALICE_DEV")
		.await?;

	let room_id =
		create_encrypted_room(&client, "sas-room").await?;

	invite_user(&client, &room_id, &bob_user_id).await?;

	let poll_interval = Duration::from_millis(2000);
	for attempt in 0..30u32 {
		let count =
			get_joined_members_count(&client, &room_id).await?;
		if count >= 2 {
			eprintln!(
				"alice: bob has joined (attempt {attempt})"
			);
			break;
		}
		if attempt == 29 {
			return Err(
				"alice: timed out waiting for bob to join"
					.into(),
			);
		}
		eprintln!(
			"alice: waiting for bob (attempt {attempt}, \
			 members: {count})"
		);
		tokio::time::sleep(poll_interval).await;
	}

	let sync_resp =
		sync_once(&client, batch.as_deref(), 1000).await?;
	batch = next_batch(&sync_resp);
	eprintln!("alice: synced after bob joined");

	let request_content = serde_json::json!({
		&bob_user_id: {
			"BOB_DEV": {
				"from_device": "ALICE_DEV",
				"methods": ["m.sas.v1"],
				"timestamp": 1000,
				"transaction_id": VERIFICATION_TXN_ID
			}
		}
	});

	send_to_device(
		&client,
		"m.key.verification.request",
		"sas_txn_01",
		&request_content,
	)
	.await?;
	eprintln!("alice: sent verification request to bob");

	let mut got_ready = false;
	let mut got_key = false;
	let mut got_mac = false;

	for attempt in 0..60u32 {
		let sync_resp =
			sync_once(&client, batch.as_deref(), 5000).await?;
		batch = next_batch(&sync_resp);


		if !got_ready {
			let ready_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.ready",
			);
			if !ready_events.is_empty() {
				eprintln!(
					"alice: received verification.ready \
					 from bob"
				);
				got_ready = true;

				let start_content = serde_json::json!({
					&bob_user_id: {
						"BOB_DEV": {
							"from_device": "ALICE_DEV",
							"method": "m.sas.v1",
							"transaction_id":
								VERIFICATION_TXN_ID,
							"key_agreement_protocols":
								["curve25519-hkdf-sha256"],
							"hashes": ["sha256"],
							"message_authentication_codes":
								["hkdf-hmac-sha256.v2"],
							"short_authentication_string":
								["emoji", "decimal"]
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.start",
					"sas_txn_03",
					&start_content,
				)
				.await?;
				eprintln!(
					"alice: sent verification.start"
				);

				let key_content = serde_json::json!({
					&bob_user_id: {
						"BOB_DEV": {
							"transaction_id":
								VERIFICATION_TXN_ID,
							"key": fake_device_key_base64()
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.key",
					"sas_txn_04",
					&key_content,
				)
				.await?;
				eprintln!("alice: sent verification.key");
			}
		}


		if got_ready && !got_key {
			let key_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.key",
			);
			if !key_events.is_empty() {
				eprintln!(
					"alice: received verification.key \
					 from bob"
				);
				got_key = true;


				let mac_content = serde_json::json!({
					&bob_user_id: {
						"BOB_DEV": {
							"transaction_id":
								VERIFICATION_TXN_ID,
							"keys": "fake_key_mac_value",
							"mac": {
								format!(
									"ed25519:ALICE_DEV"
								):
									"fake_mac_value"
							}
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.mac",
					"sas_txn_06",
					&mac_content,
				)
				.await?;
				eprintln!("alice: sent verification.mac");
			}
		}


		if got_key && !got_mac {
			let mac_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.mac",
			);
			if !mac_events.is_empty() {
				eprintln!(
					"alice: received verification.mac \
					 from bob"
				);
				got_mac = true;


				let done_content = serde_json::json!({
					&bob_user_id: {
						"BOB_DEV": {
							"transaction_id":
								VERIFICATION_TXN_ID
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.done",
					"sas_txn_08",
					&done_content,
				)
				.await?;
				eprintln!(
					"alice: sent verification.done"
				);
				break;
			}
		}

		eprintln!(
			"alice: sync poll {attempt} (ready={got_ready}, \
			 key={got_key}, mac={got_mac})"
		);
		tokio::time::sleep(poll_interval).await;
	}

	if !got_mac {
		return Err(
			"alice: timed out waiting for SAS verification \
			 to complete"
				.into(),
		);
	}

	eprintln!("alice: sas verification complete");
	Ok(())
}

/// Bob: register, upload keys, join encrypted room, respond to each
/// SAS verification step from alice.
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

	let alice_user_id = format!("@alice:{SERVER_NAME}");
	let bob_user_id = format!("@bob:{SERVER_NAME}");

	let sync_resp = sync_once(&client, None, 1000).await?;
	let mut batch = next_batch(&sync_resp);
	eprintln!("bob: initial sync complete");

	upload_device_keys(&client, &bob_user_id, "BOB_DEV").await?;

	let sas_alias = format!("#sas-room:{SERVER_NAME}");
	let _room_id = join_room_by_alias(
		&client,
		&sas_alias,
		30,
		Duration::from_millis(1000),
	)
	.await?;
	eprintln!("bob: joined sas room");

	let sync_resp =
		sync_once(&client, batch.as_deref(), 1000).await?;
	batch = next_batch(&sync_resp);
	eprintln!("bob: synced after join");

	let poll_interval = Duration::from_millis(2000);
	let mut got_request = false;
	let mut got_start = false;
	let mut got_key = false;
	let mut got_mac = false;
	let mut got_done = false;

	for attempt in 0..60u32 {
		let sync_resp =
			sync_once(&client, batch.as_deref(), 5000).await?;
		batch = next_batch(&sync_resp);


		if !got_request {
			let req_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.request",
			);
			if !req_events.is_empty() {
				eprintln!(
					"bob: received verification.request \
					 from alice"
				);
				got_request = true;


				let ready_content = serde_json::json!({
					&alice_user_id: {
						"ALICE_DEV": {
							"from_device": "BOB_DEV",
							"methods": ["m.sas.v1"],
							"transaction_id":
								VERIFICATION_TXN_ID
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.ready",
					"sas_txn_02",
					&ready_content,
				)
				.await?;
				eprintln!(
					"bob: sent verification.ready"
				);
			}
		}


		if got_request && !got_start {
			let start_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.start",
			);
			if !start_events.is_empty() {
				eprintln!(
					"bob: received verification.start \
					 from alice"
				);
				got_start = true;
			}
		}


		if got_request && !got_key {
			let key_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.key",
			);
			if !key_events.is_empty() {
				eprintln!(
					"bob: received verification.key \
					 from alice"
				);
				got_key = true;


				let key_content = serde_json::json!({
					&alice_user_id: {
						"ALICE_DEV": {
							"transaction_id":
								VERIFICATION_TXN_ID,
							"key": fake_device_key_base64()
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.key",
					"sas_txn_05",
					&key_content,
				)
				.await?;
				eprintln!("bob: sent verification.key");
			}
		}


		if got_key && !got_mac {
			let mac_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.mac",
			);
			if !mac_events.is_empty() {
				eprintln!(
					"bob: received verification.mac \
					 from alice"
				);
				got_mac = true;


				let mac_content = serde_json::json!({
					&alice_user_id: {
						"ALICE_DEV": {
							"transaction_id":
								VERIFICATION_TXN_ID,
							"keys": "fake_key_mac_value",
							"mac": {
								"ed25519:BOB_DEV":
									"fake_mac_value"
							}
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.mac",
					"sas_txn_07",
					&mac_content,
				)
				.await?;
				eprintln!("bob: sent verification.mac");
			}
		}


		if got_mac && !got_done {
			let done_events = extract_to_device_events(
				&sync_resp,
				"m.key.verification.done",
			);
			if !done_events.is_empty() {
				eprintln!(
					"bob: received verification.done \
					 from alice"
				);
				got_done = true;


				let done_content = serde_json::json!({
					&alice_user_id: {
						"ALICE_DEV": {
							"transaction_id":
								VERIFICATION_TXN_ID
						}
					}
				});

				send_to_device(
					&client,
					"m.key.verification.done",
					"sas_txn_09",
					&done_content,
				)
				.await?;
				eprintln!("bob: sent verification.done");
				break;
			}
		}

		eprintln!(
			"bob: sync poll {attempt} (request={got_request}, \
			 start={got_start}, key={got_key}, \
			 mac={got_mac}, done={got_done})"
		);
		tokio::time::sleep(poll_interval).await;
	}

	if !got_done {
		return Err(
			"bob: timed out waiting for SAS verification \
			 to complete"
				.into(),
		);
	}

	eprintln!("bob: sas verification complete");
	Ok(())
}
