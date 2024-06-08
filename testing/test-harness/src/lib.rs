#[cfg(feature = "docker-tests")]
use anyhow::{bail, Context, Result};
#[cfg(feature = "docker-tests")]
use testcontainers::core::wait::HttpWaitStrategy;
#[cfg(feature = "docker-tests")]
use testcontainers::core::{IntoContainerPort, WaitFor};
#[cfg(feature = "docker-tests")]
use testcontainers::runners::AsyncRunner;
#[cfg(feature = "docker-tests")]
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

#[cfg(feature = "docker-tests")]
const SYNAPSE_IMAGE: &str = "ghcr.io/matrix-org/synapse-service";
#[cfg(feature = "docker-tests")]
const SYNAPSE_TAG: &str = "v1.117.0";

#[cfg(feature = "docker-tests")]
const TUWUNEL_IMAGE: &str = "ghcr.io/matrix-construct/tuwunel";
#[cfg(feature = "docker-tests")]
const TUWUNEL_TAG: &str = "latest";

/// Which Matrix homeserver implementation to test against.
#[cfg(feature = "docker-tests")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerKind {
    /// Synapse (Python reference implementation).
    Synapse,
    /// Tuwunel/Conduwuit (Rust implementation, Conduit-family).
    Tuwunel,
}

#[cfg(feature = "docker-tests")]
impl std::fmt::Display for ServerKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ServerKind::Synapse => write!(f, "Synapse"),
            ServerKind::Tuwunel => write!(f, "Tuwunel"),
        }
    }
}

/// A running Matrix homeserver container for integration tests.
#[cfg(feature = "docker-tests")]
pub struct TestHomeserver {
    container: ContainerAsync<GenericImage>,
    base_url: String,
    kind: ServerKind,
}

// Always available (no feature gate) -- reused by Phase 12 embedded tests
/// A user registered on the test homeserver.
#[derive(Debug, Clone)]
pub struct RegisteredUser {
    pub user_id: String,
    pub access_token: String,
    pub device_id: String,
}

#[cfg(feature = "docker-tests")]
impl TestHomeserver {
    /// Start a fresh homeserver container of the given kind.
    /// Returns when the server is ready to accept requests.
    pub async fn start(kind: ServerKind) -> Result<Self> {
        match kind {
            ServerKind::Synapse => Self::start_synapse().await,
            ServerKind::Tuwunel => Self::start_tuwunel().await,
        }
    }

    async fn start_synapse() -> Result<Self> {
        let container = GenericImage::new(SYNAPSE_IMAGE, SYNAPSE_TAG)
            .with_exposed_port(8008.tcp())
            .with_wait_for(WaitFor::http(
                HttpWaitStrategy::new("/_matrix/client/versions")
                    .with_port(8008.tcp())
                    .with_expected_status_code(200u16),
            ))
            .with_env_var("SYNAPSE_COMPLEMENT_DATABASE", "sqlite")
            .with_env_var("SERVER_NAME", "localhost")
            .start()
            .await
            .context("failed to start Synapse container")?;

        let port = container
            .get_host_port_ipv4(8008)
            .await
            .context("failed to get mapped port")?;

        let base_url = format!("http://localhost:{port}");

        Ok(Self {
            container,
            base_url,
            kind: ServerKind::Synapse,
        })
    }

    async fn start_tuwunel() -> Result<Self> {
        let container = GenericImage::new(TUWUNEL_IMAGE, TUWUNEL_TAG)
            .with_exposed_port(6167.tcp())
            .with_wait_for(WaitFor::http(
                HttpWaitStrategy::new("/_matrix/client/versions")
                    .with_port(6167.tcp())
                    .with_expected_status_code(200u16),
            ))
            .with_env_var("TUWUNEL_SERVER_NAME", "localhost")
            .with_env_var("TUWUNEL_ADDRESS", "0.0.0.0")
            .with_env_var("TUWUNEL_PORT", "6167")
            .with_env_var("TUWUNEL_DATABASE_PATH", "/var/lib/tuwunel")
            .with_env_var("TUWUNEL_ALLOW_REGISTRATION", "true")
            .with_env_var("TUWUNEL_YES_I_AM_VERY_VERY_SURE_I_WANT_AN_OPEN_REGISTRATION_SERVER_PRONE_TO_ABUSE", "true")
            .with_env_var("TUWUNEL_LOG", "info")
            .with_env_var("TUWUNEL_ALLOW_CHECK_FOR_UPDATES", "false")
            .start()
            .await
            .context("failed to start Tuwunel container")?;

        let port = container
            .get_host_port_ipv4(6167)
            .await
            .context("failed to get mapped port")?;

        let base_url = format!("http://localhost:{port}");

        Ok(Self {
            container,
            base_url,
            kind: ServerKind::Tuwunel,
        })
    }

    /// The base URL of the running homeserver (e.g. `http://localhost:12345`).
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Which server implementation is running.
    pub fn server_kind(&self) -> ServerKind {
        self.kind
    }

    /// Retrieve container stdout logs for diagnostics.
    /// Useful when a test fails to understand what the server did.
    pub async fn logs_stdout(&self) -> Result<String> {
        let bytes = self
            .container
            .stdout_to_vec()
            .await
            .context("failed to read container stdout")?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Retrieve container stderr logs for diagnostics.
    pub async fn logs_stderr(&self) -> Result<String> {
        let bytes = self
            .container
            .stderr_to_vec()
            .await
            .context("failed to read container stderr")?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Register a user via the standard Matrix registration API.
    pub async fn register_user(&self, username: &str, password: &str) -> Result<RegisteredUser> {
        let http = reqwest::Client::new();
        let url = format!("{}/_matrix/client/v3/register", self.base_url);

        let body = serde_json::json!({
            "username": username,
            "password": password,
            "auth": { "type": "m.login.dummy" },
            "inhibit_login": false,
        });

        let resp = http
            .post(&url)
            .json(&body)
            .send()
            .await
            .context("register request failed")?;

        let status = resp.status();
        let json: serde_json::Value = resp.json().await.context("register response not JSON")?;

        if !status.is_success() {
            bail!(
                "registration failed ({}): {}",
                status,
                serde_json::to_string_pretty(&json)?
            );
        }

        Ok(RegisteredUser {
            user_id: json["user_id"]
                .as_str()
                .context("missing user_id")?
                .to_owned(),
            access_token: json["access_token"]
                .as_str()
                .context("missing access_token")?
                .to_owned(),
            device_id: json["device_id"]
                .as_str()
                .context("missing device_id")?
                .to_owned(),
        })
    }
}
