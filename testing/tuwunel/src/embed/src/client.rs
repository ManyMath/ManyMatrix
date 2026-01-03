use std::time::Duration;

use axum::Router;
use ruma::{
	OwnedEventId, OwnedRoomId, RoomId, TransactionId, UserId,
	api::{
		IncomingResponse, MatrixVersion, OutgoingRequest,
		SendAccessToken, SupportedVersions,
		client::{
			membership::{
				invite_user, join_room_by_id,
			},
			message::send_message_event,
			room::create_room,
			session::login,
			sync::sync_events,
		},
	},
	api::client::uiaa::UserIdentifier,
	events::room::message::RoomMessageEventContent,
};

use crate::{EmbeddedHomeserver, RegisteredUser, error::EmbedError};

/// Transport mode for the embedded client.
enum Transport {
	/// In-memory dispatch via axum Router.oneshot().
	InMemory(Router),

	/// Network dispatch via reqwest.
	Tcp {
		client: reqwest::Client,
		base_url: String,
	},
}

/// Typed Matrix CS API client; dispatches in-memory or over TCP
/// depending on transport mode.
pub struct EmbeddedClient {
	transport: Transport,
	server_name: String,
	access_token: Option<String>,
}

impl EmbeddedClient {
	/// Auto-detects transport mode from the server.
	pub fn from_server(server: &EmbeddedHomeserver) -> Self {
		let transport = if let Some(router) = server.router() {
			Transport::InMemory(router.clone())
		} else {
			Transport::Tcp {
				client: reqwest::Client::builder()
					.timeout(Duration::from_secs(30))
					.build()
					.expect("reqwest client"),
				base_url: server.base_url().to_owned(),
			}
		};

		Self {
			transport,
			server_name: server.server_name().to_owned(),
			access_token: None,
		}
	}

	/// Returns the server name.
	pub fn server_name(&self) -> &str { &self.server_name }

	/// Access token, if authenticated.
	pub fn access_token(&self) -> Option<&str> {
		self.access_token.as_deref()
	}

	/// Returns the base URL used for building HTTP requests.
	fn base_url(&self) -> &str {
		match &self.transport {
			| Transport::InMemory(_) => "http://localhost",
			| Transport::Tcp { base_url, .. } => base_url,
		}
	}

	/// [`SendAccessToken`] for the current auth state.
	fn access_token_send(&self) -> SendAccessToken<'_> {
		match &self.access_token {
			| Some(token) => SendAccessToken::Always(token),
			| None => SendAccessToken::None,
		}
	}

	/// Dispatch a typed ruma request.
	pub async fn request<T>(
		&self,
		request: T,
	) -> Result<T::IncomingResponse, EmbedError>
	where
		T: OutgoingRequest + Send,
		T::IncomingResponse: Send,
	{
		const VERSIONS: [MatrixVersion; 1] = [MatrixVersion::V1_11];
		let supported = SupportedVersions {
			versions: VERSIONS.into(),
			features: Default::default(),
		};

		let http_request = request
			.try_into_http_request::<Vec<u8>>(
				self.base_url(),
				self.access_token_send(),
				&supported,
			)
			.map_err(|e| EmbedError::Request {
				status: None,
				body: e.to_string(),
			})?;

		let http_response = self.raw_request(http_request).await?;

		T::IncomingResponse::try_from_http_response(http_response)
			.map_err(|e| EmbedError::Request {
				status: None,
				body: e.to_string(),
			})
	}

	/// Send a raw HTTP request through the transport and collect the
	/// full response.
	async fn raw_request(
		&self,
		http_request: http::Request<Vec<u8>>,
	) -> Result<http::Response<Vec<u8>>, EmbedError> {
		match &self.transport {
			| Transport::InMemory(router) => {
				Self::raw_request_in_memory(router, http_request).await
			},
			| Transport::Tcp { client, .. } => {
				Self::raw_request_tcp(client, http_request).await
			},
		}
	}

	/// In-memory dispatch via Router.oneshot().
	async fn raw_request_in_memory(
		router: &Router,
		http_request: http::Request<Vec<u8>>,
	) -> Result<http::Response<Vec<u8>>, EmbedError> {
		use axum::body::Body;
		use tower::ServiceExt;

		let (parts, body) = http_request.into_parts();
		let req =
			http::Request::from_parts(parts, Body::from(body));

		let response = router
			.clone()
			.oneshot(req)
			.await
			.expect("axum Router is infallible");

		let (parts, body) = response.into_parts();
		let bytes =
			axum::body::to_bytes(body, 4 * 1024 * 1024)
				.await
				.map_err(|e| EmbedError::Request {
					status: None,
					body: e.to_string(),
				})?;

		Ok(http::Response::from_parts(parts, bytes.to_vec()))
	}

	/// TCP dispatch via reqwest.
	async fn raw_request_tcp(
		client: &reqwest::Client,
		http_request: http::Request<Vec<u8>>,
	) -> Result<http::Response<Vec<u8>>, EmbedError> {
		let reqwest_request =
			reqwest::Request::try_from(http_request).map_err(|e| {
				EmbedError::Request {
					status: None,
					body: e.to_string(),
				}
			})?;

		let mut response =
			client.execute(reqwest_request).await.map_err(|e| {
				EmbedError::Request {
					status: None,
					body: e.to_string(),
				}
			})?;

		let status = response.status();
		let mut builder = http::Response::builder()
			.status(status)
			.version(response.version());

		std::mem::swap(
			response.headers_mut(),
			builder
				.headers_mut()
				.expect("http::response::Builder is usable"),
		);

		let body = response.bytes().await.map_err(|e| {
			EmbedError::Request {
				status: Some(status),
				body: e.to_string(),
			}
		})?;

		Ok(builder
			.body(body.to_vec())
			.expect("valid http response"))
	}

	/// Log in; stores access token on success.
	pub async fn login(
		&mut self,
		username: &str,
		password: &str,
	) -> Result<(), EmbedError> {
		let password_info = login::v3::Password::new(
			UserIdentifier::UserIdOrLocalpart(
				username.to_owned(),
			),
			password.to_owned(),
		);
		let req = login::v3::Request::new(
			login::v3::LoginInfo::Password(password_info),
		);

		let resp = self.request(req).await?;
		self.access_token = Some(resp.access_token);
		Ok(())
	}

	/// Sync; pass `since` for incremental or `None` for initial.
	pub async fn sync(
		&self,
		since: Option<&str>,
	) -> Result<sync_events::v3::Response, EmbedError> {
		let mut req = sync_events::v3::Request::default();
		req.since = since.map(Into::into);
		req.timeout = Some(Duration::from_secs(1));
		self.request(req).await
	}

	/// Send a text message. Returns the event ID.
	pub async fn send_message(
		&self,
		room_id: &RoomId,
		body: &str,
	) -> Result<OwnedEventId, EmbedError> {
		let content = RoomMessageEventContent::text_plain(body);
		let req = send_message_event::v3::Request::new(
			room_id.to_owned(),
			TransactionId::new(),
			&content,
		)
		.map_err(|e| EmbedError::Request {
			status: None,
			body: e.to_string(),
		})?;

		let resp = self.request(req).await?;
		Ok(resp.event_id)
	}

	/// Create a room, optionally named.
	pub async fn create_room(
		&self,
		name: Option<&str>,
	) -> Result<OwnedRoomId, EmbedError> {
		let mut req = create_room::v3::Request::new();
		req.name = name.map(|n| n.to_owned());
		let resp = self.request(req).await?;
		Ok(resp.room_id)
	}

	/// Join a room by ID.
	pub async fn join_room(
		&self,
		room_id: &RoomId,
	) -> Result<OwnedRoomId, EmbedError> {
		let req =
			join_room_by_id::v3::Request::new(room_id.to_owned());
		let resp = self.request(req).await?;
		Ok(resp.room_id)
	}

	/// Invite a user to a room.
	pub async fn invite(
		&self,
		room_id: &RoomId,
		user_id: &UserId,
	) -> Result<(), EmbedError> {
		let req = invite_user::v3::Request::new(
			room_id.to_owned(),
			invite_user::v3::InvitationRecipient::UserId {
				user_id: user_id.to_owned(),
			},
		);
		self.request(req).await?;
		Ok(())
	}

	/// UIAA two-step registration with token. Stores access token
	/// on success.
	pub async fn register(
		&mut self,
		username: &str,
		password: &str,
		registration_token: &str,
	) -> Result<RegisteredUser, EmbedError> {
		let uri = format!(
			"{}/_matrix/client/v3/register",
			self.base_url()
		);

		// Get UIAA session
		let body = serde_json::json!({
			"username": username,
			"password": password,
			"auth": { "type": "m.login.dummy" }
		});

		let req = http::Request::builder()
			.method("POST")
			.uri(&uri)
			.header("content-type", "application/json")
			.body(serde_json::to_vec(&body).map_err(|e| {
				EmbedError::Request {
					status: None,
					body: e.to_string(),
				}
			})?)
			.expect("valid request");

		let response = self.raw_request(req).await?;
		let status = response.status();
		let resp_body: serde_json::Value =
			serde_json::from_slice(response.body()).map_err(|e| {
				EmbedError::Request {
					status: Some(status),
					body: e.to_string(),
				}
			})?;

		if status.is_success() {
			return self.extract_and_store_user(&resp_body);
		}

		let session = resp_body
			.get("session")
			.and_then(|s| s.as_str())
			.ok_or_else(|| EmbedError::Request {
				status: Some(status),
				body: format!(
					"Registration UIAA response missing session \
					 for {username}: {resp_body}"
				),
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

		let req = http::Request::builder()
			.method("POST")
			.uri(&uri)
			.header("content-type", "application/json")
			.body(serde_json::to_vec(&body).map_err(|e| {
				EmbedError::Request {
					status: None,
					body: e.to_string(),
				}
			})?)
			.expect("valid request");

		let response = self.raw_request(req).await?;
		let status = response.status();
		let resp_body: serde_json::Value =
			serde_json::from_slice(response.body()).map_err(|e| {
				EmbedError::Request {
					status: Some(status),
					body: e.to_string(),
				}
			})?;

		if !status.is_success() {
			return Err(EmbedError::Request {
				status: Some(status),
				body: format!(
					"Registration failed for {username}: {resp_body}"
				),
			});
		}

		self.extract_and_store_user(&resp_body)
	}

	/// Extract and store credentials from registration response.
	fn extract_and_store_user(
		&mut self,
		body: &serde_json::Value,
	) -> Result<RegisteredUser, EmbedError> {
		let user_id = body
			.get("user_id")
			.and_then(|v| v.as_str())
			.ok_or_else(|| EmbedError::Request {
				status: None,
				body: "Registration response missing user_id"
					.to_owned(),
			})?
			.to_owned();

		let access_token = body
			.get("access_token")
			.and_then(|v| v.as_str())
			.ok_or_else(|| EmbedError::Request {
				status: None,
				body: "Registration response missing access_token"
					.to_owned(),
			})?
			.to_owned();

		self.access_token = Some(access_token.clone());

		Ok(RegisteredUser {
			user_id,
			access_token,
		})
	}
}
