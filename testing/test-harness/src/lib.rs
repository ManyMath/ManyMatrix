use std::time::Duration;

use anyhow::{bail, Context, Result};
#[cfg(feature = "docker-tests")]
use testcontainers::core::wait::{ExitWaitStrategy, HttpWaitStrategy};
#[cfg(feature = "docker-tests")]
use testcontainers::core::{IntoContainerPort, Mount, WaitFor};
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

            #[cfg(feature = "docker-tests")]
            #[tokio::test]
            async fn [<$name _continuwuity_docker>]() -> anyhow::Result<()> {
                init_tracing();
                $name($crate::ServerKind::ContinuwuityDocker).await
            }

            #[cfg(feature = "docker-tests")]
            #[tokio::test]
            async fn [<$name _dendrite_docker>]() -> anyhow::Result<()> {
                init_tracing();
                $name($crate::ServerKind::DendriteDocker).await
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

#[cfg(feature = "docker-tests")]
const CONTINUWUITY_IMAGE: &str = "ghcr.io/continuwuity/continuwuity";
#[cfg(feature = "docker-tests")]
const CONTINUWUITY_TAG: &str = "v0.5.10";
#[cfg(feature = "docker-tests")]
const CONTINUWUITY_REGISTRATION_TOKEN: &str = "manymatrix_continuwuity_docker_test_token";

#[cfg(feature = "docker-tests")]
const DENDRITE_IMAGE: &str = "matrixdotorg/dendrite-monolith";
#[cfg(feature = "docker-tests")]
const DENDRITE_TAG: &str = "latest";
/// `generate-config -ci` bakes this fixed shared secret into the generated
/// config (Dendrite's Complement test default), no need to patch the YAML.
#[cfg(feature = "docker-tests")]
const DENDRITE_SHARED_SECRET: &str = "complement";

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
    /// Docker-backed Continuwuity (conduwuit fork) server.
    #[cfg(feature = "docker-tests")]
    ContinuwuityDocker,
    /// Docker-backed Dendrite (Go reference implementation) server.
    #[cfg(feature = "docker-tests")]
    DendriteDocker,
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
            #[cfg(feature = "docker-tests")]
            Self::ContinuwuityDocker => "continuwuity-docker",
            #[cfg(feature = "docker-tests")]
            Self::DendriteDocker => "dendrite-docker",
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
            #[cfg(feature = "docker-tests")]
            Self::ContinuwuityDocker => "continuwuity",
            #[cfg(feature = "docker-tests")]
            Self::DendriteDocker => "dendrite",
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
            #[cfg(feature = "docker-tests")]
            Self::ContinuwuityDocker => "/_matrix/client/versions",
            #[cfg(feature = "docker-tests")]
            Self::DendriteDocker => "/_matrix/client/versions",
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
            #[cfg(feature = "docker-tests")]
            Self::ContinuwuityDocker => "registration_token",
            #[cfg(feature = "docker-tests")]
            Self::DendriteDocker => "shared_secret",
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
            #[cfg(feature = "docker-tests")]
            Self::ContinuwuityDocker => compat::ServerSourceMetadata {
                source_type: "docker".to_owned(),
                label: format!("{CONTINUWUITY_IMAGE}:{CONTINUWUITY_TAG}"),
                image: Some(CONTINUWUITY_IMAGE.to_owned()),
                tag: Some(CONTINUWUITY_TAG.to_owned()),
                digest: None,
                revision: None,
            },
            #[cfg(feature = "docker-tests")]
            Self::DendriteDocker => compat::ServerSourceMetadata {
                source_type: "docker".to_owned(),
                label: format!("{DENDRITE_IMAGE}:{DENDRITE_TAG}"),
                image: Some(DENDRITE_IMAGE.to_owned()),
                tag: Some(DENDRITE_TAG.to_owned()),
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
            #[cfg(feature = "docker-tests")]
            ServerKind::ContinuwuityDocker => write!(f, "Docker Continuwuity"),
            #[cfg(feature = "docker-tests")]
            ServerKind::DendriteDocker => write!(f, "Docker Dendrite"),
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
    /// Docker container paired with a bind-mounted host config directory
    /// (Dendrite: `dendrite.yaml` + signing key) that must outlive it.
    #[cfg(feature = "docker-tests")]
    DockerWithConfig(ContainerAsync<GenericImage>, tempfile::TempDir),
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
            #[cfg(feature = "docker-tests")]
            ServerKind::ContinuwuityDocker => Self::start_continuwuity_docker().await,
            #[cfg(feature = "docker-tests")]
            ServerKind::DendriteDocker => Self::start_dendrite_docker().await,
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

    /// Continuwuity (conduwuit fork) requires a one-time bootstrap: it always
    /// generates its own one-shot registration token on first boot and prints
    /// it to stdout, and the operator-configured `CONDUWUIT_REGISTRATION_TOKEN`
    /// does not take effect until *some* account has been created. So this
    /// scrapes the printed token from container logs, uses it to register a
    /// disposable bootstrap account, and only then treats the configured
    /// static token as usable for real test registrations.
    #[cfg(feature = "docker-tests")]
    async fn start_continuwuity_docker() -> Result<Self> {
        let container = GenericImage::new(CONTINUWUITY_IMAGE, CONTINUWUITY_TAG)
            .with_exposed_port(6167.tcp())
            .with_wait_for(WaitFor::http(
                HttpWaitStrategy::new("/_matrix/client/versions")
                    .with_port(6167.tcp())
                    .with_expected_status_code(200u16),
            ))
            .with_env_var("CONDUWUIT_SERVER_NAME", "localhost")
            .with_env_var("CONDUWUIT_ADDRESS", "0.0.0.0")
            .with_env_var("CONDUWUIT_PORT", "6167")
            .with_env_var("CONDUWUIT_DATABASE_PATH", "/var/lib/continuwuity")
            .with_env_var("CONDUWUIT_ALLOW_REGISTRATION", "true")
            .with_env_var("CONDUWUIT_REGISTRATION_TOKEN", CONTINUWUITY_REGISTRATION_TOKEN)
            .with_env_var("CONDUWUIT_LOG", "info")
            .with_env_var("CONDUWUIT_ALLOW_CHECK_FOR_UPDATES", "false")
            .start()
            .await
            .context("failed to start Docker Continuwuity container")?;

        let bound_port = container
            .get_host_port_ipv4(6167)
            .await
            .context("failed to get mapped Docker Continuwuity port")?;
        let base_url = format!("http://localhost:{bound_port}");

        // Continuwuity logs its welcome banner (with the auto-generated
        // bootstrap token) to stderr via `tracing`, slightly *after* it
        // starts answering HTTP requests, so the readiness probe above can
        // pass before the banner is flushed. Poll briefly for it.
        let bootstrap_token = wait_for_continuwuity_bootstrap_token(&container).await?;

        if let Err(error) = register_user_via_registration_token(
            &base_url,
            "manymatrix_continuwuity_bootstrap",
            "manymatrix_bootstrap_password",
            &bootstrap_token,
        )
        .await
        {
            // Seen intermittently on the manytier-ci runner (never locally):
            // the container passes its HTTP readiness probe and prints the
            // bootstrap token, then the registration POST gets a connection
            // refused, implying the container died in between. Attach its
            // logs so a future occurrence is diagnosable instead of a bare
            // "connection refused".
            let logs = container_log_tail(&container).await;
            return Err(error.context(format!(
                "failed to register Continuwuity bootstrap account to unlock the configured registration token; container log tail:\n{logs}"
            )));
        }

        Ok(Self {
            backend: HomeserverBackend::Docker(container),
            base_url,
            bound_port,
            kind: ServerKind::ContinuwuityDocker,
            registration_token: Some(CONTINUWUITY_REGISTRATION_TOKEN.to_owned()),
            #[cfg(feature = "hosted-tests")]
            shared_secret: None,
            run_suffix: None,
            registered: std::sync::Mutex::new(Vec::new()),
        })
    }

    /// Dendrite has no env-var config surface, unlike the Rust homeservers:
    /// it needs a real `dendrite.yaml` plus a generated Ed25519 signing key.
    /// Both are produced by one-shot `generate-config`/`generate-keys` runs
    /// of the same image against a bind-mounted host directory, before the
    /// real server container starts against that same mount.
    #[cfg(feature = "docker-tests")]
    async fn start_dendrite_docker() -> Result<Self> {
        let config_dir =
            tempfile::tempdir().context("failed to create Dendrite config directory")?;
        let host_path = config_dir
            .path()
            .to_str()
            .context("Dendrite config directory path is not valid UTF-8")?
            .to_owned();

        let config_container = GenericImage::new(DENDRITE_IMAGE, DENDRITE_TAG)
            .with_entrypoint("/usr/bin/generate-config")
            .with_wait_for(WaitFor::exit(ExitWaitStrategy::new().with_exit_code(0)))
            .with_mount(Mount::bind_mount(host_path.clone(), "/etc/dendrite"))
            .with_cmd(["-ci", "-server", "localhost", "-dir", "/etc/dendrite"])
            .start()
            .await
            .context("failed to run Dendrite generate-config")?;
        let config_yaml = config_container
            .stdout_to_vec()
            .await
            .context("failed to read Dendrite generate-config output")?;
        tokio::fs::write(config_dir.path().join("dendrite.yaml"), config_yaml)
            .await
            .context("failed to write Dendrite config file")?;
        drop(config_container);

        GenericImage::new(DENDRITE_IMAGE, DENDRITE_TAG)
            .with_entrypoint("/usr/bin/generate-keys")
            .with_wait_for(WaitFor::exit(ExitWaitStrategy::new().with_exit_code(0)))
            .with_mount(Mount::bind_mount(host_path.clone(), "/etc/dendrite"))
            .with_cmd([
                "-private-key",
                "/etc/dendrite/matrix_key.pem",
                "-tls-cert",
                "/etc/dendrite/server.crt",
                "-tls-key",
                "/etc/dendrite/server.key",
            ])
            .start()
            .await
            .context("failed to run Dendrite generate-keys")?;

        let container = GenericImage::new(DENDRITE_IMAGE, DENDRITE_TAG)
            .with_exposed_port(8008.tcp())
            .with_wait_for(WaitFor::http(
                HttpWaitStrategy::new("/_matrix/client/versions")
                    .with_port(8008.tcp())
                    .with_expected_status_code(200u16),
            ))
            .with_mount(Mount::bind_mount(host_path, "/etc/dendrite"))
            .with_cmd([
                "-config",
                "/etc/dendrite/dendrite.yaml",
                // `generate-config -ci` enables open registration guarded by
                // this same flag Synapse/Tuwunel/Continuwuity require.
                "-really-enable-open-registration",
            ])
            .start()
            .await
            .context("failed to start Docker Dendrite container")?;

        let bound_port = container
            .get_host_port_ipv4(8008)
            .await
            .context("failed to get mapped Docker Dendrite port")?;

        Ok(Self {
            backend: HomeserverBackend::DockerWithConfig(container, config_dir),
            base_url: format!("http://localhost:{bound_port}"),
            bound_port,
            kind: ServerKind::DendriteDocker,
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
            #[cfg(feature = "docker-tests")]
            HomeserverBackend::DockerWithConfig(container, config_dir) => {
                drop(container);
                drop(config_dir);
            }
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
            #[cfg(feature = "docker-tests")]
            HomeserverBackend::DockerWithConfig(container, _) => {
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
            #[cfg(feature = "docker-tests")]
            HomeserverBackend::DockerWithConfig(container, _) => {
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

        #[cfg(feature = "docker-tests")]
        if self.kind == ServerKind::ContinuwuityDocker {
            let token = self
                .registration_token
                .as_deref()
                .context("Continuwuity docker tier has no registration token configured")?;
            let user =
                register_user_via_registration_token(&self.base_url, &localpart, password, token)
                    .await?;
            self.registered
                .lock()
                .expect("registered users mutex poisoned")
                .push(user.clone());
            return Ok(user);
        }

        #[cfg(feature = "docker-tests")]
        if self.kind == ServerKind::DendriteDocker {
            let user = register_user_via_shared_secret(
                &self.base_url,
                &localpart,
                password,
                DENDRITE_SHARED_SECRET,
            )
            .await?;
            self.registered
                .lock()
                .expect("registered users mutex poisoned")
                .push(user.clone());
            return Ok(user);
        }

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

/// Polls Continuwuity's stderr for the auto-generated bootstrap token; the
/// welcome banner is flushed slightly after the HTTP readiness probe passes.
#[cfg(feature = "docker-tests")]
async fn wait_for_continuwuity_bootstrap_token(
    container: &ContainerAsync<GenericImage>,
) -> Result<String> {
    const MAX_ATTEMPTS: usize = 20;
    const RETRY_DELAY: Duration = Duration::from_millis(250);

    for attempt in 0..MAX_ATTEMPTS {
        let stderr = container
            .stderr_to_vec()
            .await
            .context("failed to read Docker Continuwuity stderr for bootstrap token")?;
        match extract_continuwuity_bootstrap_token(&String::from_utf8_lossy(&stderr)) {
            Ok(token) => return Ok(token),
            Err(_) if attempt + 1 < MAX_ATTEMPTS => tokio::time::sleep(RETRY_DELAY).await,
            Err(error) => return Err(error),
        }
    }

    bail!("Continuwuity bootstrap registration token never appeared in startup logs")
}

/// Combined stdout+stderr tail for a container, best-effort (never itself
/// fails a test, this is only ever attached as diagnostic error context).
#[cfg(feature = "docker-tests")]
async fn container_log_tail(container: &ContainerAsync<GenericImage>) -> String {
    const MAX_BYTES: usize = 4096;

    let stdout = container.stdout_to_vec().await.unwrap_or_default();
    let stderr = container.stderr_to_vec().await.unwrap_or_default();

    let tail = |bytes: &[u8]| -> String {
        let text = String::from_utf8_lossy(bytes);
        text.chars()
            .rev()
            .take(MAX_BYTES)
            .collect::<String>()
            .chars()
            .rev()
            .collect()
    };

    format!(
        "--- stdout ---\n{}\n--- stderr ---\n{}",
        tail(&stdout),
        tail(&stderr)
    )
}

/// Continuwuity prints its auto-generated bootstrap registration token as
/// `registration token \x1b[1;32mTOKEN\x1b[0m` (ANSI-colored) on first boot.
#[cfg(feature = "docker-tests")]
fn extract_continuwuity_bootstrap_token(logs: &str) -> Result<String> {
    const MARKER: &str = "registration token ";

    let after_marker = logs
        .find(MARKER)
        .map(|index| &logs[index + MARKER.len()..])
        .context("startup logs do not mention a registration token")?;
    let after_color = after_marker
        .strip_prefix("\u{1b}[1;32m")
        .unwrap_or(after_marker);
    let end = after_color
        .find(['\u{1b}', ' '])
        .context("could not find end of registration token in startup logs")?;

    Ok(after_color[..end].trim().to_owned())
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
/// Dendrite implements the same endpoint for Synapse-tooling compatibility.
#[cfg(any(feature = "docker-tests", feature = "hosted-tests"))]
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

/// Register a user against a server whose *only* registration stage is
/// `m.login.registration_token` (Continuwuity/conduwuit): probes with an
/// empty auth body to obtain a UIA session, then submits the token.
///
/// Unlike Synapse/Tuwunel, Continuwuity's response to an unsupported stage
/// (e.g. `m.login.dummy`) omits `session` entirely, so the dummy-then-token
/// fallback in [`register_user_via_api`] doesn't apply here.
#[cfg(feature = "docker-tests")]
async fn register_user_via_registration_token(
    base_url: &str,
    username: &str,
    password: &str,
    registration_token: &str,
) -> Result<RegisteredUser> {
    let http = reqwest::Client::new();
    let url = format!("{base_url}/_matrix/client/v3/register");

    let (probe_status, probe_json) =
        post_json_with_retry(&http, &url, &serde_json::json!({}), "register (flow probe)").await?;
    if probe_status.is_success() {
        return extract_registered_user(&probe_json);
    }
    let session = probe_json["session"]
        .as_str()
        .context("registration challenge missing session")?;

    let body = serde_json::json!({
        "username": username,
        "password": password,
        "auth": {
            "type": "m.login.registration_token",
            "token": registration_token,
            "session": session,
        },
        "inhibit_login": false,
    });
    let (status, json) = post_json_with_retry(&http, &url, &body, "token registration").await?;
    if status.is_success() {
        return extract_registered_user(&json);
    }

    bail!(
        "registration failed ({}): {}",
        status,
        serde_json::to_string_pretty(&json)?
    );
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
    // MAX_ATTEMPTS was 20 (20s total) until the docker-compat.yml flake
    // investigation (2026-07-04) caught a real occurrence on `manytier-ci`:
    // Continuwuity's own logs showed it listening on its mapped port almost
    // immediately, yet every one of the 20 one-second retries still got
    // "connection refused", the container was up, but the nested runner's
    // Docker port-publish path hadn't propagated yet. Widened to 90 (90s)
    // to give that propagation delay more room.
    //
    // 2026-07-04 (later same day): the flake recurred on `manytier-ci` even
    // at 90 attempts, Continuwuity's container log showed it listening at
    // 07:02:59.451Z, and the harness gave up at 07:04:29.805Z, ~90.4s later,
    // i.e. it needed *more* than 90s this time, not less. So the port-
    // publish propagation delay in this nested-runner environment is not a
    // fixed/bounded quantity; widening further only reduces the flake's
    // probability, it doesn't eliminate it. Widened again to 240 (4 min).
    // This only extends time spent when something is actually unreachable;
    // the happy path (registration succeeds immediately) is unaffected.
    const MAX_ATTEMPTS: usize = 240;
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
