use serde::Serialize;

/// Minimal tuwunel config for Shadow testing.
#[derive(Serialize, Clone, Debug)]
pub struct TuwunelConfig {
	pub global: TuwunelGlobal,
}

#[derive(Serialize, Clone, Debug)]
pub struct TuwunelGlobal {
	pub server_name: String,
	pub database_path: String,
	pub address: String,
	pub port: u16,
	pub allow_registration: bool,
	pub registration_token: String,
	pub log: String,
	/// Disable federation startup burst.
	pub startup_netburst: bool,
	/// Allow E2EE encryption.
	pub allow_encryption: bool,
	/// Enable server-to-server federation.
	#[serde(skip_serializing_if = "std::ops::Not::not")]
	pub allow_federation: bool,
	/// Trusted federation peer servers.
	#[serde(skip_serializing_if = "Vec::is_empty")]
	pub trusted_servers: Vec<String>,
	/// Accept invalid TLS certificates.
	#[serde(skip_serializing_if = "std::ops::Not::not")]
	pub allow_invalid_tls_certificates: bool,
	/// TLS certificate and key configuration for HTTPS.
	#[serde(skip_serializing_if = "Option::is_none")]
	pub tls: Option<TuwunelTls>,
}

/// TLS certificate and key paths.
#[derive(Serialize, Clone, Debug)]
pub struct TuwunelTls {
	pub certs: String,
	pub key: String,
}

impl TuwunelConfig {
	/// Create a config for a Shadow-hosted tuwunel instance.
	/// Relative `database_path` resolves from
	/// `shadow.data/hosts/<hostname>/`.
	pub fn new(server_name: &str, database_path: &str) -> Self {
		Self {
			global: TuwunelGlobal {
				server_name: server_name.to_owned(),
				database_path: database_path.to_owned(),
				address: "0.0.0.0".to_owned(),
				port: 8448,
				allow_registration: true,
				registration_token: "shadow_test_token".to_owned(),
				log: "info".to_owned(),
				startup_netburst: false,
				allow_encryption: true,
				allow_federation: false,
				trusted_servers: Vec::new(),
				allow_invalid_tls_certificates: false,
				tls: None,
			},
		}
	}

	/// Enable federation with a trusted peer server.
	pub fn with_federation(
		mut self,
		trusted_server: &str,
		allow_invalid_certs: bool,
	) -> Self {
		self.global.allow_federation = true;
		self.global.trusted_servers =
			vec![trusted_server.to_owned()];
		self.global.allow_invalid_tls_certificates =
			allow_invalid_certs;
		self
	}

	/// Configure TLS certificate and key paths.
	pub fn with_tls(
		mut self,
		cert_path: &str,
		key_path: &str,
	) -> Self {
		self.global.tls = Some(TuwunelTls {
			certs: cert_path.to_owned(),
			key: key_path.to_owned(),
		});
		self
	}

	/// Serialize to TOML string.
	pub fn to_toml(&self) -> Result<String, toml::ser::Error> {
		toml::to_string(self)
	}
}
