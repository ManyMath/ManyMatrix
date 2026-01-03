//! Common helpers for Shadow test scenarios.
//!
//! Uses ruma + reqwest directly (matrix-sdk has dep conflicts with
//! the workspace's patched async-channel fork).

use std::{
	sync::atomic::{AtomicU64, Ordering},
	time::Duration,
};

/// Registration token matching TuwunelConfig default.
pub const REGISTRATION_TOKEN: &str = "shadow_test_token";

/// Default server name for Shadow-hosted tuwunel.
pub const SERVER_NAME: &str = "tuwunel-server";

/// Default password used for all test users.
pub const DEFAULT_PASSWORD: &str = "shadow_test_pass";

/// Atomic counter for generating unique transaction IDs.
static TXN_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Generate a unique transaction ID for Matrix API calls.
fn rand_txn_id() -> u64 {
	TXN_COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// Poll `/_matrix/client/versions` until the server is ready.
pub async fn wait_for_server(
	base_url: &str,
	max_retries: u32,
	retry_interval_ms: u64,
) -> Result<(), Box<dyn std::error::Error>> {
	let client = reqwest::Client::builder()
		.timeout(Duration::from_secs(5))
		.danger_accept_invalid_certs(true)
		.build()?;

	let url = format!("{base_url}/_matrix/client/versions");
	let interval = Duration::from_millis(retry_interval_ms);

	for attempt in 0..max_retries {
		match client.get(&url).send().await {
			| Ok(resp) if resp.status().is_success() => {
				let body = resp.text().await?;
				let json: serde_json::Value =
					serde_json::from_str(&body)?;
				if json.get("versions").is_some() {
					eprintln!(
						"Server ready after {attempt} retries"
					);
					return Ok(());
				}
				eprintln!(
					"Attempt {attempt}: valid JSON but missing \
					 'versions' key"
				);
			},
			| Ok(resp) => {
				eprintln!(
					"Attempt {attempt}: HTTP {}",
					resp.status()
				);
			},
			| Err(e) => {
				eprintln!("Attempt {attempt}: {e}");
			},
		}

		tokio::time::sleep(interval).await;
	}

	Err(format!(
		"Server at {base_url} did not become ready after \
		 {max_retries} attempts"
	)
	.into())
}

/// Lightweight Matrix CS API client (ruma + reqwest).
pub struct MatrixClient {
	http: reqwest::Client,
	base_url: String,
	access_token: Option<String>,
}

impl MatrixClient {
	/// Create client and wait for server readiness.
	pub async fn new(
		server_url: &str,
	) -> Result<Self, Box<dyn std::error::Error>> {
		wait_for_server(server_url, 60, 500).await?;

		let http = reqwest::Client::builder()
			.timeout(Duration::from_secs(10))
			.danger_accept_invalid_certs(true)
			.build()?;

		Ok(Self {
			http,
			base_url: server_url.to_owned(),
			access_token: None,
		})
	}

	/// UIAA two-step registration with token.
	pub async fn register_with_token(
		&mut self,
		username: &str,
		password: &str,
		token: &str,
	) -> Result<(), Box<dyn std::error::Error>> {
		let url = format!(
			"{}/_matrix/client/v3/register",
			self.base_url
		);

		// Initial attempt to get UIAA session
		let body = serde_json::json!({
			"username": username,
			"password": password,
			"auth": {
				"type": "m.login.dummy"
			}
		});

		let resp = self.http.post(&url).json(&body).send().await?;
		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		if status.is_success() {
			if let Some(tok) = resp_body.get("access_token") {
				self.access_token =
					tok.as_str().map(|s| s.to_owned());
			}
			eprintln!("{username} registered (no UIAA required)");
			return Ok(());
		}

		let session = resp_body
			.get("session")
			.and_then(|s| s.as_str())
			.ok_or_else(|| {
				format!(
					"Registration UIAA response missing session \
					 for {username}: {resp_body}"
				)
			})?;

		// Retry with registration token
		let body = serde_json::json!({
			"username": username,
			"password": password,
			"auth": {
				"type": "m.login.registration_token",
				"token": token,
				"session": session
			}
		});

		let resp = self.http.post(&url).json(&body).send().await?;
		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		if !status.is_success() {
			return Err(format!(
				"Registration retry failed for {username}: \
				 {status} {resp_body}"
			)
			.into());
		}

		if let Some(tok) = resp_body.get("access_token") {
			self.access_token =
				tok.as_str().map(|s| s.to_owned());
		}

		eprintln!("{username} registered");
		Ok(())
	}

	/// Log in a previously-registered user.
	pub async fn login_user(
		&mut self,
		username: &str,
		password: &str,
	) -> Result<(), Box<dyn std::error::Error>> {
		let url = format!(
			"{}/_matrix/client/v3/login",
			self.base_url
		);

		let body = serde_json::json!({
			"type": "m.login.password",
			"identifier": {
				"type": "m.id.user",
				"user": username
			},
			"password": password
		});

		let resp = self.http.post(&url).json(&body).send().await?;
		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		if !status.is_success() {
			return Err(format!(
				"Login failed for {username}: {status} {resp_body}"
			)
			.into());
		}

		if let Some(tok) = resp_body.get("access_token") {
			self.access_token =
				tok.as_str().map(|s| s.to_owned());
		}

		eprintln!("{username} logged in");
		Ok(())
	}

	pub fn access_token(&self) -> Option<&str> {
		self.access_token.as_deref()
	}

	pub fn base_url(&self) -> &str { &self.base_url }

	pub fn http(&self) -> &reqwest::Client { &self.http }

	/// Create a room with an optional local alias.
	pub async fn create_room(
		&self,
		alias_local_part: Option<&str>,
	) -> Result<String, Box<dyn std::error::Error>> {
		let token = self.access_token.as_deref().ok_or(
			"create_room requires authentication",
		)?;

		let url = format!(
			"{}/_matrix/client/v3/createRoom",
			self.base_url
		);

		let mut body = serde_json::json!({});
		if let Some(alias) = alias_local_part {
			body["room_alias_name"] =
				serde_json::Value::String(alias.to_owned());
		}

		let resp = self
			.http
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

		eprintln!("Created room: {room_id}");
		Ok(room_id)
	}

	/// Send a text message to a room. Returns the event ID.
	pub async fn send_text_message(
		&self,
		room_id: &str,
		text: &str,
	) -> Result<String, Box<dyn std::error::Error>> {
		let token = self.access_token.as_deref().ok_or(
			"send_text_message requires authentication",
		)?;

		let txn_id = format!("txn_{}", rand_txn_id());

		let url = format!(
			"{}/_matrix/client/v3/rooms/{}/send/m.room.message/{}",
			self.base_url, room_id, txn_id
		);

		let body = serde_json::json!({
			"msgtype": "m.text",
			"body": text
		});

		let resp = self
			.http
			.put(&url)
			.bearer_auth(token)
			.json(&body)
			.send()
			.await?;

		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		if !status.is_success() {
			return Err(format!(
				"send message failed: {status} {resp_body}"
			)
			.into());
		}

		let event_id = resp_body
			.get("event_id")
			.and_then(|v| v.as_str())
			.ok_or("send response missing event_id")?
			.to_owned();

		eprintln!("Sent message, event_id: {event_id}");
		Ok(event_id)
	}

	/// Join a room by alias or room ID.
	pub async fn join_room(
		&self,
		room_id_or_alias: &str,
	) -> Result<String, Box<dyn std::error::Error>> {
		let token = self.access_token.as_deref().ok_or(
			"join_room requires authentication",
		)?;

		let encoded = room_id_or_alias
			.replace('#', "%23")
			.replace(':', "%3A");
		let url = format!(
			"{}/_matrix/client/v3/join/{}",
			self.base_url, encoded
		);

		let resp = self
			.http
			.post(&url)
			.bearer_auth(token)
			.json(&serde_json::json!({}))
			.send()
			.await?;

		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		if !status.is_success() {
			return Err(format!(
				"join room failed: {status} {resp_body}"
			)
			.into());
		}

		let room_id = resp_body
			.get("room_id")
			.and_then(|v| v.as_str())
			.ok_or("join response missing room_id")?
			.to_owned();

		eprintln!("Joined room: {room_id}");
		Ok(room_id)
	}

	/// Join a room with retries; alias may not propagate immediately.
	pub async fn join_room_with_retry(
		&self,
		room_id_or_alias: &str,
		max_retries: u32,
		retry_interval_ms: u64,
	) -> Result<String, Box<dyn std::error::Error>> {
		let interval =
			Duration::from_millis(retry_interval_ms);

		for attempt in 0..max_retries {
			match self.join_room(room_id_or_alias).await {
				| Ok(room_id) => {
					eprintln!(
						"Joined after {attempt} retries"
					);
					return Ok(room_id);
				},
				| Err(e) => {
					eprintln!(
						"Join attempt {attempt}: {e}"
					);
					tokio::time::sleep(interval).await;
				},
			}
		}

		Err(format!(
			"Failed to join {room_id_or_alias} after \
			 {max_retries} attempts"
		)
		.into())
	}

	pub async fn sync(
		&self,
		since: Option<&str>,
	) -> Result<serde_json::Value, Box<dyn std::error::Error>>
	{
		let token = self.access_token.as_deref().ok_or(
			"sync requires authentication",
		)?;

		let mut url = format!(
			"{}/_matrix/client/v3/sync?timeout=30000",
			self.base_url
		);
		if let Some(since_token) = since {
			url.push_str("&since=");
			url.push_str(since_token);
		}

		let resp = self
			.http
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
}

pub async fn create_sdk_client(
	server_url: &str,
) -> Result<MatrixClient, Box<dyn std::error::Error>> {
	MatrixClient::new(server_url).await
}

pub async fn register_with_token(
	client: &mut MatrixClient,
	username: &str,
	password: &str,
	token: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	client.register_with_token(username, password, token).await
}

pub async fn login_user(
	client: &mut MatrixClient,
	username: &str,
	password: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	client.login_user(username, password).await
}
