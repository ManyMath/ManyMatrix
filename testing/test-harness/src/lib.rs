use anyhow::{bail, Context, Result};
#[cfg(feature = "docker-tests")]
use testcontainers::core::wait::HttpWaitStrategy;
#[cfg(feature = "docker-tests")]
use testcontainers::core::{IntoContainerPort, WaitFor};
#[cfg(feature = "docker-tests")]
use testcontainers::runners::AsyncRunner;
#[cfg(feature = "docker-tests")]
use testcontainers::{ContainerAsync, GenericImage, ImageExt};
#[cfg(feature = "embedded-tests")]
use tuwunel_embed::EmbeddedHomeserver;

#[cfg(feature = "shadow-tests")]
pub mod shadow;

const EMBEDDED_SERVER_NAME: &str = "localhost";
const EMBEDDED_REGISTRATION_TOKEN: &str = "manymatrix_embed_test_token";

#[cfg(feature = "docker-tests")]
const SYNAPSE_IMAGE: &str = "ghcr.io/matrix-org/synapse-service";
#[cfg(feature = "docker-tests")]
const SYNAPSE_TAG: &str = "v1.117.0";

#[cfg(feature = "docker-tests")]
const TUWUNEL_IMAGE: &str = "ghcr.io/matrix-construct/tuwunel";
#[cfg(feature = "docker-tests")]
const TUWUNEL_TAG: &str = "latest";

/// Which Matrix homeserver implementation to test against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerKind {
    /// Embedded tuwunel running in-process over TCP.
    #[cfg(feature = "embedded-tests")]
    TuwunelEmbedded,
    /// Synapse (Python reference implementation).
    #[cfg(feature = "docker-tests")]
    Synapse,
    /// Docker-backed Tuwunel/Conduwuit server.
    #[cfg(feature = "docker-tests")]
    TuwunelDocker,
}

impl ServerKind {
    pub fn is_synapse(self) -> bool {
        #[cfg(feature = "docker-tests")]
        if matches!(self, Self::Synapse) {
            return true;
        }

        false
    }
}

impl std::fmt::Display for ServerKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            #[cfg(feature = "embedded-tests")]
            ServerKind::TuwunelEmbedded => write!(f, "Embedded Tuwunel"),
            #[cfg(feature = "docker-tests")]
            ServerKind::Synapse => write!(f, "Synapse"),
            #[cfg(feature = "docker-tests")]
            ServerKind::TuwunelDocker => write!(f, "Docker Tuwunel"),
        }
    }
}

enum HomeserverBackend {
    #[cfg(feature = "embedded-tests")]
    Embedded(EmbeddedHomeserver),
    #[cfg(feature = "docker-tests")]
    Docker(ContainerAsync<GenericImage>),
}

/// A running Matrix homeserver for integration tests.
pub struct TestHomeserver {
    backend: HomeserverBackend,
    base_url: String,
    bound_port: u16,
    kind: ServerKind,
    registration_token: Option<String>,
}

/// A user registered on the test homeserver.
#[derive(Debug, Clone)]
pub struct RegisteredUser {
    pub user_id: String,
    pub access_token: String,
    pub device_id: String,
}

impl TestHomeserver {
    /// Start a fresh homeserver of the given kind.
    /// Returns when the server is ready to accept requests.
    pub async fn start(kind: ServerKind) -> Result<Self> {
        match kind {
            #[cfg(feature = "embedded-tests")]
            ServerKind::TuwunelEmbedded => Self::start_tuwunel_embedded().await,
            #[cfg(feature = "docker-tests")]
            ServerKind::Synapse => Self::start_synapse().await,
            #[cfg(feature = "docker-tests")]
            ServerKind::TuwunelDocker => Self::start_tuwunel_docker().await,
        }
    }

    #[cfg(feature = "embedded-tests")]
    async fn start_tuwunel_embedded() -> Result<Self> {
        let server = tuwunel_embed::Builder::new(EMBEDDED_SERVER_NAME)
            .registration_token(EMBEDDED_REGISTRATION_TOKEN)
            .start()
            .await
            .context("failed to start embedded Tuwunel server")?;

        let base_url = server.base_url().to_owned();
        let bound_port = parse_port(&base_url)?;

        Ok(Self {
            backend: HomeserverBackend::Embedded(server),
            base_url,
            bound_port,
            kind: ServerKind::TuwunelEmbedded,
            registration_token: Some(EMBEDDED_REGISTRATION_TOKEN.to_owned()),
        })
    }

    #[cfg(feature = "docker-tests")]
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

        let bound_port = container
            .get_host_port_ipv4(8008)
            .await
            .context("failed to get mapped Synapse port")?;

        Ok(Self {
            backend: HomeserverBackend::Docker(container),
            base_url: format!("http://localhost:{bound_port}"),
            bound_port,
            kind: ServerKind::Synapse,
            registration_token: None,
        })
    }

    #[cfg(feature = "docker-tests")]
    async fn start_tuwunel_docker() -> Result<Self> {
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
            .with_env_var(
                "TUWUNEL_YES_I_AM_VERY_VERY_SURE_I_WANT_AN_OPEN_REGISTRATION_SERVER_PRONE_TO_ABUSE",
                "true",
            )
            .with_env_var("TUWUNEL_LOG", "info")
            .with_env_var("TUWUNEL_ALLOW_CHECK_FOR_UPDATES", "false")
            .start()
            .await
            .context("failed to start Docker Tuwunel container")?;

        let bound_port = container
            .get_host_port_ipv4(6167)
            .await
            .context("failed to get mapped Docker Tuwunel port")?;

        Ok(Self {
            backend: HomeserverBackend::Docker(container),
            base_url: format!("http://localhost:{bound_port}"),
            bound_port,
            kind: ServerKind::TuwunelDocker,
            registration_token: None,
        })
    }

    /// The base URL of the running homeserver.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// The actual port the homeserver bound to.
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Which server implementation is running.
    pub fn server_kind(&self) -> ServerKind {
        self.kind
    }

    /// Stop the homeserver.
    pub async fn stop(self) -> Result<()> {
        match self.backend {
            #[cfg(feature = "embedded-tests")]
            HomeserverBackend::Embedded(server) => server
                .stop()
                .await
                .context("failed to stop embedded Tuwunel server")?,
            #[cfg(feature = "docker-tests")]
            HomeserverBackend::Docker(container) => drop(container),
        }

        Ok(())
    }

    /// Retrieve homeserver stdout logs for diagnostics.
    pub async fn logs_stdout(&self) -> Result<String> {
        match &self.backend {
            #[cfg(feature = "embedded-tests")]
            HomeserverBackend::Embedded(_) => {
                Ok("embedded backend does not expose captured stdout".to_owned())
            }
            #[cfg(feature = "docker-tests")]
            HomeserverBackend::Docker(container) => {
                let bytes = container
                    .stdout_to_vec()
                    .await
                    .context("failed to read container stdout")?;
                Ok(String::from_utf8_lossy(&bytes).into_owned())
            }
        }
    }

    /// Retrieve homeserver stderr logs for diagnostics.
    pub async fn logs_stderr(&self) -> Result<String> {
        match &self.backend {
            #[cfg(feature = "embedded-tests")]
            HomeserverBackend::Embedded(_) => {
                Ok("embedded backend does not expose captured stderr".to_owned())
            }
            #[cfg(feature = "docker-tests")]
            HomeserverBackend::Docker(container) => {
                let bytes = container
                    .stderr_to_vec()
                    .await
                    .context("failed to read container stderr")?;
                Ok(String::from_utf8_lossy(&bytes).into_owned())
            }
        }
    }

    /// Register a user via the Matrix registration API.
    pub async fn register_user(&self, username: &str, password: &str) -> Result<RegisteredUser> {
        register_user_via_api(
            &self.base_url,
            username,
            password,
            self.registration_token.as_deref(),
        )
        .await
    }
}

fn parse_port(base_url: &str) -> Result<u16> {
    let (_, port) = base_url
        .rsplit_once(':')
        .context("homeserver base URL missing port")?;

    port.parse::<u16>()
        .context("homeserver base URL contains invalid port")
}

async fn register_user_via_api(
    base_url: &str,
    username: &str,
    password: &str,
    registration_token: Option<&str>,
) -> Result<RegisteredUser> {
    let http = reqwest::Client::new();
    let url = format!("{base_url}/_matrix/client/v3/register");

    let initial_body = serde_json::json!({
        "username": username,
        "password": password,
        "auth": { "type": "m.login.dummy" },
        "inhibit_login": false,
    });

    let initial_resp = http
        .post(&url)
        .json(&initial_body)
        .send()
        .await
        .context("register request failed")?;

    let initial_status = initial_resp.status();
    let initial_json: serde_json::Value = initial_resp
        .json()
        .await
        .context("register response was not JSON")?;

    if initial_status.is_success() {
        return extract_registered_user(&initial_json);
    }

    if initial_status == reqwest::StatusCode::UNAUTHORIZED {
        if let Some(token) = registration_token {
            let session = initial_json["session"]
                .as_str()
                .context("registration challenge missing session")?;

            let token_body = serde_json::json!({
                "username": username,
                "password": password,
                "auth": {
                    "type": "m.login.registration_token",
                    "token": token,
                    "session": session,
                },
                "inhibit_login": false,
            });

            let token_resp = http
                .post(&url)
                .json(&token_body)
                .send()
                .await
                .context("token registration request failed")?;

            let token_status = token_resp.status();
            let token_json: serde_json::Value = token_resp
                .json()
                .await
                .context("token registration response was not JSON")?;

            if token_status.is_success() {
                return extract_registered_user(&token_json);
            }

            bail!(
                "registration failed ({}): {}",
                token_status,
                serde_json::to_string_pretty(&token_json)?
            );
        }
    }

    bail!(
        "registration failed ({}): {}",
        initial_status,
        serde_json::to_string_pretty(&initial_json)?
    );
}

fn extract_registered_user(json: &serde_json::Value) -> Result<RegisteredUser> {
    Ok(RegisteredUser {
        user_id: json["user_id"]
            .as_str()
            .context("missing user_id")?
            .to_owned(),
        access_token: json["access_token"]
            .as_str()
            .context("missing access_token")?
            .to_owned(),
        device_id: json["device_id"].as_str().unwrap_or_default().to_owned(),
    })
}
