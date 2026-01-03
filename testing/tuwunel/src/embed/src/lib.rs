//! Embeddable tuwunel homeserver for in-process testing.
//!
//! Two transport modes: TCP (default) or in-memory via
//! [`Builder::listening(false)`] + `tower::ServiceExt::oneshot`.
//! [`EmbeddedHomeserver::client`] returns a typed ruma client that
//! auto-detects the active transport.

pub mod client;
pub mod config;
pub mod error;

use std::{path::PathBuf, sync::Arc};

use tuwunel_core::Server;
use tuwunel_service::Services;

pub use self::{
	client::EmbeddedClient, config::Builder, error::EmbedError,
};

/// Credentials returned from user registration.
pub struct RegisteredUser {
	/// Full Matrix user ID, e.g. `@alice:example.localhost`.
	pub user_id: String,

	/// Access token for authenticating subsequent requests.
	pub access_token: String,
}

/// An embedded tuwunel homeserver running in the current process.
pub struct EmbeddedHomeserver {
	/// Core server state.
	server: Arc<Server>,

	/// Running services; held to keep them alive.
	services: Arc<Services>,

	/// Background task running the server listener.
	run_handle: tokio::task::JoinHandle<tuwunel_core::Result>,

	/// URL with actual bound port (e.g. `http://127.0.0.1:12345`).
	base_url: String,

	/// Matrix server name (e.g. `example.localhost`).
	server_name: String,

	/// Tempdir ownership for RocksDB; dropped on stop.
	_db_dir: Option<tempfile::TempDir>,

	/// Logging flame guard; held for lifetime.
	_flame_guard: tuwunel::logging::TracingFlameGuard,

	/// In-memory axum Router when started with `listening(false)`.
	/// `None` in TCP mode.
	router: Option<axum::Router>,

	/// Guard keeping the Services Arc alive for the Router's lifetime.
	/// Declared after `router` so it outlives the Router on drop.
	_guard: Option<tuwunel_api::router::state::Guard>,
}

impl EmbeddedHomeserver {
	/// Returns the base URL of the running server.
	pub fn base_url(&self) -> &str { &self.base_url }

	/// Returns the Matrix server name.
	pub fn server_name(&self) -> &str { &self.server_name }

	/// In-memory Router, or `None` in TCP mode.
	pub fn router(&self) -> Option<&axum::Router> {
		self.router.as_ref()
	}

	/// Create a typed client for this server.
	pub fn client(&self) -> EmbeddedClient {
		EmbeddedClient::from_server(self)
	}

	/// Returns the database path used by this server instance.
	pub fn database_path(&self) -> PathBuf {
		PathBuf::from(&self.server.config.database_path)
	}

	/// Returns `true` if the server is in in-memory (no TCP) mode.
	pub fn is_in_memory(&self) -> bool { self.router.is_some() }


	/// Convenience: start a server with default settings for the given
	/// server name.
	pub async fn start(
		server_name: &str,
	) -> Result<Self, EmbedError> {
		Builder::new(server_name).start().await
	}

	/// Restart the server, preserving database state and config.
	pub async fn restart(self) -> Result<Self, EmbedError> {
		let db_path = self.database_path();
		let server_name = self.server_name().to_owned();
		let in_memory = self.is_in_memory();
		let registration_token =
			self.server.config.registration_token.clone();

		// Stop the current server
		self.stop().await?;

		// Rebuild with the same database path
		let mut builder = Builder::new(&server_name)
			.database_path(db_path)
			.listening(!in_memory);

		if let Some(ref token) = registration_token {
			builder = builder.registration_token(token);
		}

		builder.start().await
	}

	/// Stop the server and wait for shutdown.
	pub async fn stop(self) -> Result<(), EmbedError> {
		self.server
			.shutdown()
			.map_err(|e| EmbedError::Shutdown(e.to_string()))?;

		self.run_handle
			.await
			.map_err(|e| EmbedError::Shutdown(e.to_string()))?
			.map_err(|e| EmbedError::Shutdown(e.to_string()))?;

		// Drop before stop() checks Arc refcounts
		drop(self.router);
		drop(self._guard);

		tuwunel_router::stop(self.services)
			.await
			.map_err(|e| EmbedError::Shutdown(e.to_string()))?;

		Ok(())
	}

	/// Register a user via UIAA two-step flow. Dispatches in-memory
	/// or over TCP depending on transport mode.
	pub async fn register_user(
		&self,
		username: &str,
		password: &str,
		registration_token: &str,
	) -> Result<RegisteredUser, Box<dyn std::error::Error + Send + Sync>>
	{
		if let Some(router) = &self.router {
			self.register_user_in_memory(
				router, username, password, registration_token,
			)
			.await
		} else {
			self.register_user_tcp(
				username, password, registration_token,
			)
			.await
		}
	}

	/// Register a user via in-memory Router dispatch (no network).
	async fn register_user_in_memory(
		&self,
		router: &axum::Router,
		username: &str,
		password: &str,
		registration_token: &str,
	) -> Result<RegisteredUser, Box<dyn std::error::Error + Send + Sync>>
	{
		use axum::body::Body;
		use http::Request;
		use tower::ServiceExt;

		let uri = "/_matrix/client/v3/register";

		// Get UIAA session
		let body = serde_json::json!({
			"username": username,
			"password": password,
			"auth": { "type": "m.login.dummy" }
		});

		let req = Request::builder()
			.method("POST")
			.uri(uri)
			.header("content-type", "application/json")
			.body(Body::from(serde_json::to_vec(&body)?))
			.expect("valid request");

		let response = router
			.clone()
			.oneshot(req)
			.await
			.expect("axum Router is infallible");
		let status = response.status();
		let body_bytes =
			axum::body::to_bytes(response.into_body(), 1024 * 1024)
				.await?;
		let resp_body: serde_json::Value =
			serde_json::from_slice(&body_bytes)?;

		// Succeeded without UIAA
		if status.is_success() {
			return Ok(extract_registered_user(&resp_body)?);
		}

		// UIAA 401: extract session
		let session = resp_body
			.get("session")
			.and_then(|s| s.as_str())
			.ok_or_else(|| {
				format!(
					"Registration UIAA response missing session \
					 for {username}: {resp_body}"
				)
			})?;

		// Complete with token
		let body = serde_json::json!({
			"username": username,
			"password": password,
			"auth": {
				"type": "m.login.registration_token",
				"token": registration_token,
				"session": session
			}
		});

		let req = Request::builder()
			.method("POST")
			.uri(uri)
			.header("content-type", "application/json")
			.body(Body::from(serde_json::to_vec(&body)?))
			.expect("valid request");

		let response = router
			.clone()
			.oneshot(req)
			.await
			.expect("axum Router is infallible");
		let status = response.status();
		let body_bytes =
			axum::body::to_bytes(response.into_body(), 1024 * 1024)
				.await?;
		let resp_body: serde_json::Value =
			serde_json::from_slice(&body_bytes)?;

		if !status.is_success() {
			return Err(format!(
				"Registration failed for {username}: \
				 {status} {resp_body}"
			)
			.into());
		}

		Ok(extract_registered_user(&resp_body)?)
	}

	/// Register a user via TCP/reqwest (network mode).
	async fn register_user_tcp(
		&self,
		username: &str,
		password: &str,
		registration_token: &str,
	) -> Result<RegisteredUser, Box<dyn std::error::Error + Send + Sync>>
	{
		let client = reqwest::Client::builder()
			.timeout(std::time::Duration::from_secs(10))
			.build()?;

		let url =
			format!("{}/_matrix/client/v3/register", self.base_url);

		// Get UIAA session
		let body = serde_json::json!({
			"username": username,
			"password": password,
			"auth": { "type": "m.login.dummy" }
		});

		let resp = client.post(&url).json(&body).send().await?;
		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		// Succeeded without UIAA
		if status.is_success() {
			return Ok(extract_registered_user(&resp_body)?);
		}

		// UIAA 401: extract session
		let session = resp_body
			.get("session")
			.and_then(|s| s.as_str())
			.ok_or_else(|| {
				format!(
					"Registration UIAA response missing session \
					 for {username}: {resp_body}"
				)
			})?;

		// Complete with token
		let body = serde_json::json!({
			"username": username,
			"password": password,
			"auth": {
				"type": "m.login.registration_token",
				"token": registration_token,
				"session": session
			}
		});

		let resp = client.post(&url).json(&body).send().await?;
		let status = resp.status();
		let resp_body: serde_json::Value = resp.json().await?;

		if !status.is_success() {
			return Err(format!(
				"Registration failed for {username}: \
				 {status} {resp_body}"
			)
			.into());
		}

		Ok(extract_registered_user(&resp_body)?)
	}
}

/// Extract user_id and access_token from a successful registration
/// response.
fn extract_registered_user(
	body: &serde_json::Value,
) -> Result<RegisteredUser, Box<dyn std::error::Error + Send + Sync>> {
	let user_id = body
		.get("user_id")
		.and_then(|v| v.as_str())
		.ok_or("Registration response missing user_id")?
		.to_owned();

	let access_token = body
		.get("access_token")
		.and_then(|v| v.as_str())
		.ok_or("Registration response missing access_token")?
		.to_owned();

	Ok(RegisteredUser {
		user_id,
		access_token,
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	// Integration tests require a full tuwunel build (RocksDB, etc.).
	// Run with: cargo test -p tuwunel-embed -- --ignored

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_single_instance_lifecycle() {
		let server = EmbeddedHomeserver::start("test-single.localhost")
			.await
			.expect("server should start");

		// Verify base_url is reachable
		let resp = reqwest::get(&format!(
			"{}/_matrix/client/versions",
			server.base_url()
		))
		.await
		.expect("HTTP request should succeed");
		assert!(resp.status().is_success());

		server.stop().await.expect("server should stop cleanly");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_multi_instance_concurrent() {
		let server1 =
			EmbeddedHomeserver::start("test-multi1.localhost")
				.await
				.expect("server 1 should start");

		let server2 =
			EmbeddedHomeserver::start("test-multi2.localhost")
				.await
				.expect("server 2 should start");

		// Both should be reachable
		let resp1 = reqwest::get(&format!(
			"{}/_matrix/client/versions",
			server1.base_url()
		))
		.await
		.expect("server 1 reachable");
		assert!(resp1.status().is_success());

		let resp2 = reqwest::get(&format!(
			"{}/_matrix/client/versions",
			server2.base_url()
		))
		.await
		.expect("server 2 reachable");
		assert!(resp2.status().is_success());

		// Different ports (port 0 assigns unique ports)
		assert_ne!(server1.base_url(), server2.base_url());

		server1.stop().await.expect("server 1 stops");
		server2.stop().await.expect("server 2 stops");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_register_user() {
		let server = Builder::new("test-register.localhost")
			.registration_token("test_token_123")
			.start()
			.await
			.expect("server should start");

		let user = server
			.register_user("alice", "password123", "test_token_123")
			.await
			.expect("registration should succeed");

		assert!(!user.user_id.is_empty());
		assert!(!user.access_token.is_empty());
		assert!(user.user_id.contains("alice"));

		server.stop().await.expect("server should stop");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_in_memory_versions() {
		use axum::body::Body;
		use http::Request;
		use tower::ServiceExt;

		let server = Builder::new("test-inmem.localhost")
			.listening(false)
			.start()
			.await
			.expect("server should start in in-memory mode");

		let router = server
			.router()
			.expect("in-memory mode should expose router");

		let req = Request::builder()
			.method("GET")
			.uri("/_matrix/client/versions")
			.body(Body::empty())
			.expect("valid request");

		let response = router
			.clone()
			.oneshot(req)
			.await
			.expect("router dispatch should succeed");

		assert!(
			response.status().is_success(),
			"versions endpoint should return 200"
		);

		let body_bytes =
			axum::body::to_bytes(response.into_body(), 1024 * 1024)
				.await
				.expect("should read body");
		let json: serde_json::Value =
			serde_json::from_slice(&body_bytes)
				.expect("should be valid JSON");

		assert!(
			json.get("versions").is_some(),
			"response should contain versions key"
		);

		server.stop().await.expect("server should stop");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_in_memory_register_user() {
		let server = Builder::new("test-inmem-reg.localhost")
			.listening(false)
			.registration_token("inmem_token")
			.start()
			.await
			.expect("server should start");

		assert!(
			server.router().is_some(),
			"in-memory mode should expose router"
		);

		let user = server
			.register_user("bob", "password456", "inmem_token")
			.await
			.expect("in-memory registration should succeed");

		assert!(
			user.user_id.contains("bob"),
			"user_id should contain username"
		);
		assert!(
			!user.access_token.is_empty(),
			"access_token should not be empty"
		);

		server.stop().await.expect("server should stop");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_tcp_mode_no_router() {
		let server = Builder::new("test-tcp-nort.localhost")
			.start()
			.await
			.expect("server should start in TCP mode");

		assert!(
			server.router().is_none(),
			"TCP mode should not expose router"
		);

		server.stop().await.expect("server should stop");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_embedded_client_register() {
		let server = Builder::new("test-client-reg.localhost")
			.listening(false)
			.registration_token("client_token")
			.start()
			.await
			.expect("server should start");

		let mut client = server.client();
		let user = client
			.register("charlie", "pass123", "client_token")
			.await
			.expect("registration via client should succeed");

		assert!(user.user_id.contains("charlie"));
		assert!(!user.access_token.is_empty());

		server.stop().await.expect("server should stop");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_embedded_client_create_room() {
		let server = Builder::new("test-client-room.localhost")
			.listening(false)
			.registration_token("room_token")
			.start()
			.await
			.expect("server should start");

		let mut client = server.client();
		client
			.register("roomuser", "pass123", "room_token")
			.await
			.expect("register should succeed");

		let room_id = client
			.create_room(Some("Test Room"))
			.await
			.expect("create_room should succeed");

		assert!(!room_id.as_str().is_empty());

		server.stop().await.expect("server should stop");
	}

	#[tokio::test]
	#[ignore = "requires full tuwunel build with RocksDB"]
	async fn test_restart_preserves_data() {
		let server = Builder::new("test-restart.localhost")
			.listening(false)
			.registration_token("restart_token")
			.start()
			.await
			.expect("server should start");

		// Register a user before restart
		let mut client = server.client();
		client
			.register("persist_user", "pass123", "restart_token")
			.await
			.expect("register should succeed");

		// Restart the server (consumes and returns new instance)
		let server =
			server.restart().await.expect("restart should succeed");

		// Login with the previously registered user on new instance
		let mut client = server.client();
		client
			.login("persist_user", "pass123")
			.await
			.expect(
				"login after restart should succeed with \
				 persisted data",
			);

		server.stop().await.expect("server should stop");
	}
}
