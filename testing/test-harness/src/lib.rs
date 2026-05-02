use std::time::Duration;

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

pub mod compat;

#[macro_export]
macro_rules! e2e_test {
    ($name:ident) => {
        paste::paste! {
            #[cfg(feature = "embedded-tests")]
            #[tokio::test]
            async fn [<$name _embedded>]() -> anyhow::Result<()> {
                init_tracing();
                $name($crate::ServerKind::TuwunelEmbedded).await
            }

            #[cfg(feature = "docker-tests")]
            #[tokio::test]
            async fn [<$name _tuwunel_docker>]() -> anyhow::Result<()> {
                init_tracing();
                $name($crate::ServerKind::TuwunelDocker).await
            }

            #[cfg(feature = "docker-tests")]
            #[tokio::test]
            async fn [<$name _synapse>]() -> anyhow::Result<()> {
                init_tracing();
                $name($crate::ServerKind::Synapse).await
            }

            #[cfg(feature = "hosted-tests")]
            #[tokio::test]
            async fn [<$name _hosted_synapse>]() -> anyhow::Result<()> {
                init_tracing();
                $name($crate::ServerKind::HostedSynapse).await
            }

            #[cfg(feature = "hosted-tests")]
            #[tokio::test]
            async fn [<$name _hosted_tuwunel>]() -> anyhow::Result<()> {
                init_tracing();
                $name($crate::ServerKind::HostedTuwunel).await
            }
        }
    };
}

#[cfg(feature = "embedded-tests")]
const EMBEDDED_SERVER_NAME: &str = "localhost";
#[cfg(feature = "embedded-tests")]
const EMBEDDED_REGISTRATION_TOKEN: &str = "manymatrix_embed_test_token";

#[cfg(feature = "docker-tests")]
const SYNAPSE_IMAGE: &str = "ghcr.io/matrix-org/synapse-service";
#[cfg(feature = "docker-tests")]
const SYNAPSE_TAG: &str = "v1.117.0";

#[cfg(feature = "docker-tests")]
const TUWUNEL_IMAGE: &str = "ghcr.io/matrix-construct/tuwunel";
#[cfg(feature = "docker-tests")]
const TUWUNEL_TAG: &str = "latest";

#[cfg(feature = "hosted-tests")]
const HOSTED_SYNAPSE_URL_ENV: &str = "MANYMATRIX_HOSTED_SYNAPSE_URL";
#[cfg(feature = "hosted-tests")]
const HOSTED_SYNAPSE_SECRET_ENV: &str = "MANYMATRIX_HOSTED_SYNAPSE_REGISTRATION_SECRET";
#[cfg(feature = "hosted-tests")]
const HOSTED_TUWUNEL_URL_ENV: &str = "MANYMATRIX_HOSTED_TUWUNEL_URL";
#[cfg(feature = "hosted-tests")]
const HOSTED_TUWUNEL_TOKEN_ENV: &str = "MANYMATRIX_HOSTED_TUWUNEL_REGISTRATION_TOKEN";

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
    /// Permanently hosted Synapse reached via `MANYMATRIX_HOSTED_SYNAPSE_URL`.
    #[cfg(feature = "hosted-tests")]
    HostedSynapse,
    /// Permanently hosted Tuwunel reached via `MANYMATRIX_HOSTED_TUWUNEL_URL`.
    #[cfg(feature = "hosted-tests")]
    HostedTuwunel,
    /// Placeholder used only when compiling harness helpers without homeserver tiers.
    #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
    Unavailable,
}

impl ServerKind {
    pub fn slug(self) -> &'static str {
        match self {
            #[cfg(feature = "embedded-tests")]
            Self::TuwunelEmbedded => "tuwunel-embedded",
            #[cfg(feature = "docker-tests")]
            Self::Synapse => "synapse",
            #[cfg(feature = "docker-tests")]
            Self::TuwunelDocker => "tuwunel-docker",
            #[cfg(feature = "hosted-tests")]
            Self::HostedSynapse => "synapse-hosted",
            #[cfg(feature = "hosted-tests")]
            Self::HostedTuwunel => "tuwunel-hosted",
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            Self::Unavailable => "unavailable",
        }
    }

    pub fn implementation_family(self) -> &'static str {
        match self {
            #[cfg(feature = "embedded-tests")]
            Self::TuwunelEmbedded => "tuwunel",
            #[cfg(feature = "docker-tests")]
            Self::Synapse => "synapse",
            #[cfg(feature = "docker-tests")]
            Self::TuwunelDocker => "tuwunel",
            #[cfg(feature = "hosted-tests")]
            Self::HostedSynapse => "synapse",
            #[cfg(feature = "hosted-tests")]
            Self::HostedTuwunel => "tuwunel",
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            Self::Unavailable => "unavailable",
        }
    }

    pub fn readiness_endpoint(self) -> &'static str {
        match self {
            #[cfg(feature = "embedded-tests")]
            Self::TuwunelEmbedded => "/_matrix/client/versions",
            #[cfg(feature = "docker-tests")]
            Self::Synapse => "/_matrix/client/versions",
            #[cfg(feature = "docker-tests")]
            Self::TuwunelDocker => "/_matrix/client/versions",
            #[cfg(feature = "hosted-tests")]
            Self::HostedSynapse => "/_matrix/client/versions",
            #[cfg(feature = "hosted-tests")]
            Self::HostedTuwunel => "/_matrix/client/versions",
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            Self::Unavailable => "/_matrix/client/versions",
        }
    }

    pub fn registration_mode(self) -> &'static str {
        match self {
            #[cfg(feature = "embedded-tests")]
            Self::TuwunelEmbedded => "registration_token",
            #[cfg(feature = "docker-tests")]
            Self::Synapse => "open_registration",
            #[cfg(feature = "docker-tests")]
            Self::TuwunelDocker => "open_registration",
            #[cfg(feature = "hosted-tests")]
            Self::HostedSynapse => "shared_secret",
            #[cfg(feature = "hosted-tests")]
            Self::HostedTuwunel => "registration_token",
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            Self::Unavailable => "unavailable",
        }
    }

    pub fn source_metadata(self) -> compat::ServerSourceMetadata {
        match self {
            #[cfg(feature = "embedded-tests")]
            Self::TuwunelEmbedded => compat::ServerSourceMetadata {
                source_type: "embedded".to_owned(),
                label: "tuwunel-embed@3c69fdd5".to_owned(),
                image: None,
                tag: None,
                digest: None,
                revision: Some("3c69fdd5".to_owned()),
            },
            #[cfg(feature = "docker-tests")]
            Self::Synapse => compat::ServerSourceMetadata {
                source_type: "docker".to_owned(),
                label: format!("{SYNAPSE_IMAGE}:{SYNAPSE_TAG}"),
                image: Some(SYNAPSE_IMAGE.to_owned()),
                tag: Some(SYNAPSE_TAG.to_owned()),
                digest: None,
                revision: None,
            },
            #[cfg(feature = "docker-tests")]
            Self::TuwunelDocker => compat::ServerSourceMetadata {
                source_type: "docker".to_owned(),
                label: format!("{TUWUNEL_IMAGE}:{TUWUNEL_TAG}"),
                image: Some(TUWUNEL_IMAGE.to_owned()),
                tag: Some(TUWUNEL_TAG.to_owned()),
                digest: None,
                revision: None,
            },
            #[cfg(feature = "hosted-tests")]
            Self::HostedSynapse => compat::ServerSourceMetadata {
                source_type: "hosted".to_owned(),
                label: format!("hosted synapse via ${HOSTED_SYNAPSE_URL_ENV}"),
                image: None,
                tag: None,
                digest: None,
                revision: None,
            },
            #[cfg(feature = "hosted-tests")]
            Self::HostedTuwunel => compat::ServerSourceMetadata {
                source_type: "hosted".to_owned(),
                label: format!("hosted tuwunel via ${HOSTED_TUWUNEL_URL_ENV}"),
                image: None,
                tag: None,
                digest: None,
                revision: None,
            },
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            Self::Unavailable => compat::ServerSourceMetadata {
                source_type: "unavailable".to_owned(),
                label: "no homeserver test tier enabled".to_owned(),
                image: None,
                tag: None,
                digest: None,
                revision: None,
            },
        }
    }

    pub fn is_synapse(self) -> bool {
        #[cfg(feature = "docker-tests")]
        if matches!(self, Self::Synapse) {
            return true;
        }

        #[cfg(feature = "hosted-tests")]
        if matches!(self, Self::HostedSynapse) {
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
            #[cfg(feature = "hosted-tests")]
            ServerKind::HostedSynapse => write!(f, "Hosted Synapse"),
            #[cfg(feature = "hosted-tests")]
            ServerKind::HostedTuwunel => write!(f, "Hosted Tuwunel"),
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            ServerKind::Unavailable => write!(f, "Unavailable"),
        }
    }
}

enum HomeserverBackend {
    #[cfg(feature = "embedded-tests")]
    Embedded(EmbeddedHomeserver),
    #[cfg(feature = "docker-tests")]
    Docker(ContainerAsync<GenericImage>),
    /// Permanently hosted server; nothing to start or stop, but users created
    /// during the run are cleaned up (rooms left and forgotten) on `stop()`.
    #[cfg(feature = "hosted-tests")]
    Hosted,
    #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
    #[allow(dead_code)]
    Unavailable,
}

/// A running Matrix homeserver for integration tests.
pub struct TestHomeserver {
    backend: HomeserverBackend,
    base_url: String,
    bound_port: u16,
    kind: ServerKind,
    registration_token: Option<String>,
    /// Synapse `registration_shared_secret` for the hosted admin register API.
    #[cfg(feature = "hosted-tests")]
    shared_secret: Option<String>,
    /// Per-run suffix appended to requested usernames on hosted servers so
    /// runs never collide; `None` on throwaway local servers.
    run_suffix: Option<String>,
    /// Users registered through this handle, tracked for hosted cleanup.
    registered: std::sync::Mutex<Vec<RegisteredUser>>,
}

/// A user registered on the test homeserver.
#[derive(Debug, Clone)]
pub struct RegisteredUser {
    pub user_id: String,
    /// Actual localpart on the server; differs from the requested username on
    /// hosted tiers, where a per-run suffix keeps names unique.
    pub localpart: String,
    pub access_token: String,
    pub device_id: String,
}

impl TestHomeserver {
    /// Start a homeserver of the given kind; blocks until ready.
    pub async fn start(kind: ServerKind) -> Result<Self> {
        match kind {
            #[cfg(feature = "embedded-tests")]
            ServerKind::TuwunelEmbedded => Self::start_tuwunel_embedded().await,
            #[cfg(feature = "docker-tests")]
            ServerKind::Synapse => Self::start_synapse().await,
            #[cfg(feature = "docker-tests")]
            ServerKind::TuwunelDocker => Self::start_tuwunel_docker().await,
            #[cfg(feature = "hosted-tests")]
            ServerKind::HostedSynapse | ServerKind::HostedTuwunel => {
                Self::start_hosted(kind).await
            }
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            ServerKind::Unavailable => bail!("no homeserver test tier enabled"),
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
            #[cfg(feature = "hosted-tests")]
            shared_secret: None,
            run_suffix: None,
            registered: std::sync::Mutex::new(Vec::new()),
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
            #[cfg(feature = "hosted-tests")]
            shared_secret: None,
            run_suffix: None,
            registered: std::sync::Mutex::new(Vec::new()),
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
            #[cfg(feature = "hosted-tests")]
            shared_secret: None,
            run_suffix: None,
            registered: std::sync::Mutex::new(Vec::new()),
        })
    }

    #[cfg(feature = "hosted-tests")]
    async fn start_hosted(kind: ServerKind) -> Result<Self> {
        let (url_env, secret_env) = match kind {
            ServerKind::HostedSynapse => (HOSTED_SYNAPSE_URL_ENV, HOSTED_SYNAPSE_SECRET_ENV),
            ServerKind::HostedTuwunel => (HOSTED_TUWUNEL_URL_ENV, HOSTED_TUWUNEL_TOKEN_ENV),
            // Reachable only when other tiers are also compiled in.
            #[allow(unreachable_patterns)]
            _ => bail!("start_hosted called with non-hosted server kind {kind}"),
        };

        let base_url = std::env::var(url_env)
            .with_context(|| format!("{url_env} must be set to run the hosted test tier"))?
            .trim_end_matches('/')
            .to_owned();
        let secret = std::env::var(secret_env)
            .with_context(|| format!("{secret_env} must be set to run the hosted test tier"))?;

        wait_for_readiness(&base_url).await?;

        let (registration_token, shared_secret) = match kind {
            ServerKind::HostedSynapse => (None, Some(secret)),
            _ => (Some(secret), None),
        };

        Ok(Self {
            backend: HomeserverBackend::Hosted,
            bound_port: hosted_port(&base_url)?,
            base_url,
            kind,
            registration_token,
            shared_secret,
            run_suffix: Some(run_suffix()),
            registered: std::sync::Mutex::new(Vec::new()),
        })
    }

    /// Base URL of the running homeserver.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Port the homeserver bound to.
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Which implementation is running.
    pub fn server_kind(&self) -> ServerKind {
        self.kind
    }

    /// Stable metadata used by compatibility reports.
    pub fn metadata(&self) -> compat::ServerMetadata {
        compat::ServerMetadata {
            kind: self.kind.slug().to_owned(),
            display_name: self.kind.to_string(),
            implementation_family: self.kind.implementation_family().to_owned(),
            base_url: self.base_url.clone(),
            readiness_endpoint: self.kind.readiness_endpoint().to_owned(),
            registration_mode: self.kind.registration_mode().to_owned(),
            source: self.kind.source_metadata(),
        }
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
            #[cfg(feature = "hosted-tests")]
            HomeserverBackend::Hosted => {
                let users = self
                    .registered
                    .into_inner()
                    .expect("registered users mutex poisoned");
                cleanup_hosted_users(&self.base_url, users).await;
            }
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            HomeserverBackend::Unavailable => {}
        }

        Ok(())
    }

    /// Captured stdout from the homeserver.
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
            #[cfg(feature = "hosted-tests")]
            HomeserverBackend::Hosted => {
                Ok("hosted backend does not expose captured stdout".to_owned())
            }
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            HomeserverBackend::Unavailable => Ok("no homeserver backend enabled".to_owned()),
        }
    }

    /// Captured stderr from the homeserver.
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
            #[cfg(feature = "hosted-tests")]
            HomeserverBackend::Hosted => {
                Ok("hosted backend does not expose captured stderr".to_owned())
            }
            #[cfg(not(any(
        feature = "embedded-tests",
        feature = "docker-tests",
        feature = "hosted-tests"
    )))]
            HomeserverBackend::Unavailable => Ok("no homeserver backend enabled".to_owned()),
        }
    }

    /// Register a user on the homeserver.
    ///
    /// On hosted servers the requested username gets a per-run suffix so runs
    /// never collide; log in with the returned [`RegisteredUser::localpart`].
    pub async fn register_user(&self, username: &str, password: &str) -> Result<RegisteredUser> {
        let localpart = match &self.run_suffix {
            Some(suffix) => format!("{username}_{suffix}"),
            None => username.to_owned(),
        };

        #[cfg(feature = "hosted-tests")]
        let user = match &self.shared_secret {
            Some(secret) => {
                register_user_via_shared_secret(&self.base_url, &localpart, password, secret)
                    .await?
            }
            None => {
                register_user_via_api(
                    &self.base_url,
                    &localpart,
                    password,
                    self.registration_token.as_deref(),
                )
                .await?
            }
        };

        #[cfg(not(feature = "hosted-tests"))]
        let user = register_user_via_api(
            &self.base_url,
            &localpart,
            password,
            self.registration_token.as_deref(),
        )
        .await?;

        self.registered
            .lock()
            .expect("registered users mutex poisoned")
            .push(user.clone());

        Ok(user)
    }
}

#[cfg(any(feature = "embedded-tests", feature = "docker-tests"))]
fn parse_port(base_url: &str) -> Result<u16> {
    let (_, port) = base_url
        .rsplit_once(':')
        .context("homeserver base URL missing port")?;

    port.parse::<u16>()
        .context("homeserver base URL contains invalid port")
}

/// Unique-enough suffix for one `TestHomeserver` handle: wall-clock nanos plus
/// a process-local counter, so parallel tests and repeated runs never collide.
#[cfg(feature = "hosted-tests")]
fn run_suffix() -> String {
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as u64)
        .unwrap_or_default();
    let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);

    format!("{nanos:x}{sequence:x}")
}

#[cfg(feature = "hosted-tests")]
fn hosted_port(base_url: &str) -> Result<u16> {
    let rest = base_url
        .strip_prefix("https://")
        .or_else(|| base_url.strip_prefix("http://"))
        .with_context(|| format!("hosted homeserver URL {base_url} must be http(s)"))?;

    match rest.split_once(':') {
        Some((_, port)) => port
            .parse::<u16>()
            .with_context(|| format!("hosted homeserver URL {base_url} has an invalid port")),
        None if base_url.starts_with("https://") => Ok(443),
        None => Ok(80),
    }
}

#[cfg(feature = "hosted-tests")]
async fn wait_for_readiness(base_url: &str) -> Result<()> {
    const MAX_ATTEMPTS: usize = 30;
    const RETRY_DELAY: Duration = Duration::from_secs(1);

    let http = reqwest::Client::new();
    let url = format!("{base_url}/_matrix/client/versions");

    for attempt in 0..MAX_ATTEMPTS {
        match http.get(&url).send().await {
            Ok(response) if response.status().is_success() => return Ok(()),
            _ if attempt + 1 < MAX_ATTEMPTS => tokio::time::sleep(RETRY_DELAY).await,
            Ok(response) => bail!(
                "hosted homeserver at {base_url} is not ready: HTTP {}",
                response.status()
            ),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("hosted homeserver at {base_url} is unreachable"));
            }
        }
    }

    bail!("hosted homeserver at {base_url} readiness probe exhausted retries")
}

/// Register a user through Synapse's shared-secret admin API
/// (`/_synapse/admin/v1/register`, HMAC-SHA1 over `nonce\0user\0password\0notadmin`).
#[cfg(feature = "hosted-tests")]
async fn register_user_via_shared_secret(
    base_url: &str,
    username: &str,
    password: &str,
    shared_secret: &str,
) -> Result<RegisteredUser> {
    use hmac::Mac;

    let http = reqwest::Client::new();
    let url = format!("{base_url}/_synapse/admin/v1/register");

    let nonce_json: serde_json::Value = http
        .get(&url)
        .send()
        .await
        .context("shared-secret register nonce request failed")?
        .json()
        .await
        .context("shared-secret register nonce response was not JSON")?;
    let nonce = nonce_json["nonce"]
        .as_str()
        .context("shared-secret register nonce missing")?;

    let mut mac = hmac::Hmac::<sha1::Sha1>::new_from_slice(shared_secret.as_bytes())
        .context("invalid Synapse registration shared secret")?;
    for part in [nonce, username, password] {
        mac.update(part.as_bytes());
        mac.update(b"\x00");
    }
    mac.update(b"notadmin");
    let mac_hex = hex::encode(mac.finalize().into_bytes());

    let body = serde_json::json!({
        "nonce": nonce,
        "username": username,
        "password": password,
        "admin": false,
        "mac": mac_hex,
    });

    let (status, json) = post_json_with_retry(&http, &url, &body, "shared-secret register").await?;
    if !status.is_success() {
        bail!(
            "shared-secret registration failed ({}): {}",
            status,
            serde_json::to_string_pretty(&json)?
        );
    }

    extract_registered_user(&json)
}

/// Best-effort hosted-server hygiene: each user registered during the run
/// leaves and forgets every room it joined. Failures are logged, not fatal.
#[cfg(feature = "hosted-tests")]
async fn cleanup_hosted_users(base_url: &str, users: Vec<RegisteredUser>) {
    let http = reqwest::Client::new();

    for user in users {
        let response = match http
            .get(format!("{base_url}/_matrix/client/v3/joined_rooms"))
            .bearer_auth(&user.access_token)
            .send()
            .await
        {
            Ok(response) => response,
            Err(error) => {
                tracing::warn!("hosted cleanup: joined_rooms for {} failed: {error}", user.user_id);
                continue;
            }
        };

        let joined: Vec<String> = match response.json::<serde_json::Value>().await {
            Ok(json) => json["joined_rooms"]
                .as_array()
                .map(|rooms| {
                    rooms
                        .iter()
                        .filter_map(|room| room.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default(),
            Err(error) => {
                tracing::warn!(
                    "hosted cleanup: joined_rooms for {} was not JSON: {error}",
                    user.user_id
                );
                continue;
            }
        };

        for room in joined {
            for action in ["leave", "forget"] {
                if let Err(error) = http
                    .post(format!("{base_url}/_matrix/client/v3/rooms/{room}/{action}"))
                    .bearer_auth(&user.access_token)
                    .json(&serde_json::json!({}))
                    .send()
                    .await
                {
                    tracing::warn!(
                        "hosted cleanup: {action} {room} for {} failed: {error}",
                        user.user_id
                    );
                }
            }
        }
    }
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

    let (initial_status, initial_json) =
        post_json_with_retry(&http, &url, &initial_body, "register").await?;

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

            let (token_status, token_json) =
                post_json_with_retry(&http, &url, &token_body, "token registration").await?;

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

async fn post_json_with_retry(
    http: &reqwest::Client,
    url: &str,
    body: &serde_json::Value,
    request_name: &str,
) -> Result<(reqwest::StatusCode, serde_json::Value)> {
    const MAX_ATTEMPTS: usize = 20;
    const RETRY_DELAY: Duration = Duration::from_secs(1);

    for attempt in 0..MAX_ATTEMPTS {
        let response = match http.post(url).json(body).send().await {
            Ok(response) => response,
            Err(_) if attempt + 1 < MAX_ATTEMPTS => {
                tokio::time::sleep(RETRY_DELAY).await;
                continue;
            }
            Err(error) => {
                return Err(error).with_context(|| format!("{request_name} request failed"));
            }
        };

        let status = response.status();
        let text = response
            .text()
            .await
            .with_context(|| format!("{request_name} response body could not be read"))?;

        match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(json) => return Ok((status, json)),
            Err(_) if attempt + 1 < MAX_ATTEMPTS => {
                tokio::time::sleep(RETRY_DELAY).await;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("{request_name} response was not JSON: {}", text.trim())
                });
            }
        }
    }

    bail!("{request_name} request exhausted retries without a JSON response")
}

fn extract_registered_user(json: &serde_json::Value) -> Result<RegisteredUser> {
    let user_id = json["user_id"]
        .as_str()
        .context("missing user_id")?
        .to_owned();
    let localpart = user_id
        .strip_prefix('@')
        .and_then(|rest| rest.split_once(':'))
        .map(|(localpart, _)| localpart.to_owned())
        .with_context(|| format!("user_id {user_id} is not a valid Matrix user ID"))?;

    Ok(RegisteredUser {
        user_id,
        localpart,
        access_token: json["access_token"]
            .as_str()
            .context("missing access_token")?
            .to_owned(),
        device_id: json["device_id"].as_str().unwrap_or_default().to_owned(),
    })
}
