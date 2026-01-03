use std::{net::TcpListener, path::PathBuf, sync::Arc, time::Duration};

use figment::{Figment, providers::Serialized};
use tuwunel_core::config::Config;

use crate::{EmbeddedHomeserver, error::EmbedError};

/// Builder for an embedded tuwunel homeserver.
pub struct Builder {
	server_name: String,
	port: u16,
	address: String,
	registration_token: Option<String>,
	log_level: String,
	database_path: Option<PathBuf>,
	worker_threads: usize,
	listening: bool,
	allow_federation: bool,
	trusted_servers: Vec<String>,
	allow_invalid_tls_certificates: bool,
}

impl Builder {
	/// Defaults: port 0 (auto), 127.0.0.1, warn, auto tempdir, 2
	/// workers.
	pub fn new(server_name: &str) -> Self {
		Self {
			server_name: server_name.to_owned(),
			port: 0,
			address: "127.0.0.1".to_owned(),
			registration_token: None,
			log_level: "warn".to_owned(),
			database_path: None,
			worker_threads: 2,
			listening: true,
			allow_federation: false,
			trusted_servers: Vec::new(),
			allow_invalid_tls_certificates: false,
		}
	}

	/// Set the TCP port to listen on. Use 0 for auto-assignment.
	pub fn port(mut self, port: u16) -> Self {
		self.port = port;
		self
	}

	/// Set the listen address.
	pub fn address(mut self, address: &str) -> Self {
		self.address = address.to_owned();
		self
	}

	/// Set a registration token (enables open registration with token).
	pub fn registration_token(mut self, token: &str) -> Self {
		self.registration_token = Some(token.to_owned());
		self
	}

	/// Set the log level filter string.
	pub fn log_level(mut self, level: &str) -> Self {
		self.log_level = level.to_owned();
		self
	}

	/// Set an explicit database path. If not set, a temporary directory
	/// is created automatically.
	pub fn database_path(mut self, path: PathBuf) -> Self {
		self.database_path = Some(path);
		self
	}

	/// Set the number of tokio worker threads.
	pub fn worker_threads(mut self, n: usize) -> Self {
		self.worker_threads = n;
		self
	}

	/// When `false`, use [`EmbeddedHomeserver::router`] for
	/// in-memory dispatch instead of TCP.
	pub fn listening(mut self, listening: bool) -> Self {
		self.listening = listening;
		self
	}

	/// Enable or disable federation with other Matrix servers.
	pub fn allow_federation(mut self, allow: bool) -> Self {
		self.allow_federation = allow;
		self
	}

	/// Set the list of trusted servers for federation key
	/// notarization.
	pub fn trusted_servers(mut self, servers: Vec<String>) -> Self {
		self.trusted_servers = servers;
		self
	}

	/// Allow invalid TLS certificates when federating (useful for
	/// testing with self-signed certs).
	pub fn allow_invalid_tls_certificates(mut self, allow: bool) -> Self {
		self.allow_invalid_tls_certificates = allow;
		self
	}

	/// Returns the configured server name.
	pub fn server_name(&self) -> &str { &self.server_name }

	/// Build a [`Figment`] config (no env vars or CLI args).
	pub fn build_figment(&self, db_path: &std::path::Path) -> Figment {
		let mut figment = Figment::new()
			.merge(Serialized::default("server_name", &self.server_name))
			.merge(Serialized::default(
				"database_path",
				db_path.to_str().unwrap_or_default(),
			))
			.merge(Serialized::default("port", [self.port]))
			.merge(Serialized::default("address", [&self.address]))
			.merge(Serialized::default("listening", self.listening))
			.merge(Serialized::default(
				"allow_registration",
				self.registration_token.is_some(),
			))
			.merge(Serialized::default("startup_netburst", false))
			.merge(Serialized::default("log", &self.log_level))
			.merge(Serialized::default("log_global_default", false))
			.merge(Serialized::default(
				"allow_federation",
				self.allow_federation,
			))
			.merge(Serialized::default(
				"trusted_servers",
				&self.trusted_servers,
			))
			.merge(Serialized::default(
				"allow_invalid_tls_certificates",
				self.allow_invalid_tls_certificates,
			));

		if let Some(ref token) = self.registration_token {
			figment =
				figment.merge(Serialized::default("registration_token", token));
		}

		figment
	}

	/// Start the server.
	pub async fn start(
		mut self,
	) -> Result<EmbeddedHomeserver, EmbedError> {
		let db_dir = if self.database_path.is_none() {
			Some(
				tempfile::TempDir::new()
					.map_err(|e| EmbedError::Config(e.to_string()))?,
			)
		} else {
			None
		};

		let db_path = match self.database_path {
			| Some(ref p) => p.clone(),
			| None => {
				db_dir
					.as_ref()
					.expect("tempdir created")
					.path()
					.to_owned()
			},
		};

		// Pre-bind to discover actual port
		if self.listening && self.port == 0 {
			let listener =
				TcpListener::bind(format!("{}:0", self.address))
					.map_err(|e| EmbedError::Config(e.to_string()))?;
			let actual_port = listener
				.local_addr()
				.map_err(|e| EmbedError::Config(e.to_string()))?
				.port();
			self.port = actual_port;
			drop(listener);
		}

		let server_name = self.server_name.clone();

		let figment = self.build_figment(&db_path);
		let config = Config::new(&figment)
			.map_err(|e| EmbedError::Config(e.to_string()))?;

		let (flame_guard, logger) =
			tuwunel::logging::init(&config)
				.map_err(|e| EmbedError::Startup(e.to_string()))?;

		let server = Arc::new(tuwunel_core::Server::new(
			config,
			Some(tokio::runtime::Handle::current()),
			logger,
		));

		let services = tuwunel_router::start(&server)
			.await
			.map_err(|e| EmbedError::Startup(e.to_string()))?;

		let run_services = services.clone();
		let run_handle = tokio::spawn(async move {
			tuwunel_router::run(&run_services).await
		});

		if self.listening {
			let base_url =
				format!("http://{}:{}", self.address, self.port);
			wait_for_ready(&base_url).await?;

			Ok(EmbeddedHomeserver {
				server,
				services,
				run_handle,
				base_url,
				server_name,
				_db_dir: db_dir,
				_flame_guard: flame_guard,
				router: None,
				_guard: None,
			})
		} else {
			use std::net::{IpAddr, Ipv4Addr, SocketAddr};

			use axum::extract::connect_info::MockConnectInfo;

			let (router, guard) =
				tuwunel_router::build_router(&services)
					.map_err(|e| EmbedError::Startup(e.to_string()))?;

			// Synthetic ConnectInfo for handlers that extract SocketAddr
			let router = router.layer(MockConnectInfo(
				SocketAddr::new(
					IpAddr::V4(Ipv4Addr::LOCALHOST),
					0,
				),
			));

			let base_url = "http://127.0.0.1:0".to_owned();

			Ok(EmbeddedHomeserver {
				server,
				services,
				run_handle,
				base_url,
				server_name,
				_db_dir: db_dir,
				_flame_guard: flame_guard,
				router: Some(router),
				_guard: Some(guard),
			})
		}
	}
}

/// Poll the server's versions endpoint until it responds successfully.
async fn wait_for_ready(base_url: &str) -> Result<(), EmbedError> {
	let url = format!("{base_url}/_matrix/client/versions");
	let client = reqwest::Client::new();

	for _ in 0..60 {
		match client.get(&url).send().await {
			| Ok(resp) if resp.status().is_success() => return Ok(()),
			| _ => tokio::time::sleep(Duration::from_millis(200)).await,
		}
	}

	Err(EmbedError::Startup(format!(
		"Server at {base_url} did not become ready within 12 seconds"
	)))
}
