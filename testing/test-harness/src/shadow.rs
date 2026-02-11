//! Shadow-backed tests require:
//! - a Linux host
//! - `x86_64-unknown-linux-gnu` dynamically linked binaries (`ldd` must succeed)
//! - `seccomp=unconfined` when executed inside Docker or another restricted container

use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{bail, Context, Result};
use serde::Serialize;
use tempfile::TempDir;

pub use shadow_common::{
    FEDERATED_MESSAGE_TEXT, LATENCY_ENCRYPTED_MESSAGE_TEXT, LATENCY_MESSAGE_TEXT,
};

const ALICE_START_TIME: &str = "8s";
const BOB_START_TIME: &str = "10s";
const ALICE_E2EE_START_TIME: &str = "6s";
const BOB_E2EE_START_TIME: &str = "8s";
const ALICE_FEDERATED_HOST_NAME: &str = "alice-server";
const BOB_FEDERATED_HOST_NAME: &str = "bob-server";
const ALICE_FEDERATED_HOST_IP: &str = "11.0.0.2";
const BOB_FEDERATED_HOST_IP: &str = "11.0.0.4";
const ALICE_FEDERATED_SERVER_NAME: &str = "alice-server:8448";
const BOB_FEDERATED_SERVER_NAME: &str = "bob-server:8448";
const FEDERATED_SHADOW_STOP_TIME: &str = "120s";
const SHADOW_CLIENT_SUBCOMMAND: &str = "latency-message";
const SHADOW_CLIENT_E2EE_SUBCOMMAND: &str = "latency-encrypted-message";
const SHADOW_CLIENT_FEDERATED_SUBCOMMAND: &str = "federated-message";
const SHADOW_DATA_DIR_NAME: &str = "shadow.data";
const SHADOW_STOP_TIME: &str = "45s";
const SHADOW_E2EE_STOP_TIME: &str = "90s";
const TUWUNEL_DATABASE_PATH: &str = "data";
const TUWUNEL_SERVER_NAME: &str = "tuwunel-server";

pub struct ShadowRun {
    _tempdir: TempDir,
    pub topology: TopologyFixture,
    pub shadow_config_path: PathBuf,
    pub tuwunel_config_path: PathBuf,
    pub result: ShadowResult,
}

impl ShadowRun {
    pub fn shadow_config(&self) -> Result<String> {
        fs::read_to_string(&self.shadow_config_path).with_context(|| {
            format!(
                "failed to read generated Shadow config at {}",
                self.shadow_config_path.display()
            )
        })
    }
}

pub struct ShadowResult {
    pub exit_code: i32,
    pub data_dir: PathBuf,
    pub seed: u32,
    pub stdout: String,
    pub stderr: String,
}

impl ShadowResult {
    pub fn success(&self) -> bool {
        self.exit_code == 0
    }

    pub fn hosts_dir(&self) -> PathBuf {
        self.data_dir.join("hosts")
    }

    pub fn find_host_stderrs(&self, hostname: &str) -> Vec<PathBuf> {
        let host_dir = self.hosts_dir().join(hostname);
        glob_files(&host_dir, "stderr")
    }

    pub fn first_host_stderr(&self, hostname: &str) -> Result<String> {
        let stderr_path = self
            .find_host_stderrs(hostname)
            .into_iter()
            .next()
            .with_context(|| {
                format!(
                    "no stderr files found for host '{hostname}' in {}",
                    self.hosts_dir().display()
                )
            })?;

        fs::read_to_string(&stderr_path)
            .with_context(|| format!("failed to read host stderr at {}", stderr_path.display()))
    }

    pub fn print_failure_diagnostics(&self) {
        eprintln!("=== Shadow simulation FAILED ===");
        eprintln!("Seed: {}", self.seed);
        eprintln!("Data directory: {}", self.data_dir.display());
        eprintln!("Host logs: {}/", self.hosts_dir().display());
        if !self.stderr.is_empty() {
            eprintln!("--- Shadow stderr ---");
            let lines: Vec<&str> = self.stderr.lines().collect();
            let start = lines.len().saturating_sub(50);
            for line in &lines[start..] {
                eprintln!("{line}");
            }
        }

        if let Ok(hosts) = fs::read_dir(self.hosts_dir()) {
            for host in hosts.flatten() {
                let hostname = host.file_name().to_string_lossy().into_owned();
                for stderr_path in glob_files(&host.path(), "stderr") {
                    if let Ok(stderr) = fs::read_to_string(&stderr_path) {
                        if stderr.is_empty() {
                            continue;
                        }

                        eprintln!("--- Host stderr: {hostname} ---");
                        let lines: Vec<&str> = stderr.lines().collect();
                        let start = lines.len().saturating_sub(50);
                        for line in &lines[start..] {
                            eprintln!("{line}");
                        }
                    }
                }
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct TopologyFixture {
    pub latency_ms: u32,
    pub packet_loss: f64,
    pub bandwidth_down: String,
    pub bandwidth_up: String,
}

impl TopologyFixture {
    pub fn slow_mobile() -> Self {
        Self {
            latency_ms: 150,
            packet_loss: 0.01,
            bandwidth_down: "5 Mbit".to_owned(),
            bandwidth_up: "1 Mbit".to_owned(),
        }
    }

    pub fn federated_pair() -> Self {
        Self {
            latency_ms: 50,
            packet_loss: 0.0,
            bandwidth_down: "10 Mbit".to_owned(),
            bandwidth_up: "10 Mbit".to_owned(),
        }
    }

    fn to_gml(&self) -> String {
        format!(
            "graph [\n\
             \x20 directed 0\n\
             \x20 node [\n\
             \x20   id 0\n\
             \x20   host_bandwidth_down \"{bd}\"\n\
             \x20   host_bandwidth_up \"{bu}\"\n\
             \x20 ]\n\
             \x20 edge [\n\
             \x20   source 0\n\
             \x20   target 0\n\
             \x20   latency \"{lat} ms\"\n\
             \x20   packet_loss {loss:.6}\n\
             \x20 ]\n\
             ]",
            bd = self.bandwidth_down,
            bu = self.bandwidth_up,
            lat = self.latency_ms,
            loss = self.packet_loss,
        )
    }

    fn to_network(&self) -> Network {
        Network {
            graph: NetworkGraph {
                graph_type: "gml".to_owned(),
                inline: Some(self.to_gml()),
            },
        }
    }

    fn to_federated_pair_gml(&self) -> String {
        format!(
            "graph [\n\
             \x20 directed 0\n\
             \x20 node [\n\
             \x20   id 0\n\
             \x20   host_bandwidth_down \"{bd}\"\n\
             \x20   host_bandwidth_up \"{bu}\"\n\
             \x20 ]\n\
             \x20 node [\n\
             \x20   id 1\n\
             \x20   host_bandwidth_down \"{bd}\"\n\
             \x20   host_bandwidth_up \"{bu}\"\n\
             \x20 ]\n\
             \x20 edge [\n\
             \x20   source 0\n\
             \x20   target 0\n\
             \x20   latency \"1 ms\"\n\
             \x20   packet_loss 0.0\n\
             \x20 ]\n\
             \x20 edge [\n\
             \x20   source 1\n\
             \x20   target 1\n\
             \x20   latency \"1 ms\"\n\
             \x20   packet_loss 0.0\n\
             \x20 ]\n\
             \x20 edge [\n\
             \x20   source 0\n\
             \x20   target 1\n\
             \x20   latency \"{lat} ms\"\n\
             \x20   packet_loss {loss:.6}\n\
             \x20 ]\n\
             \x20 edge [\n\
             \x20   source 1\n\
             \x20   target 0\n\
             \x20   latency \"{lat} ms\"\n\
             \x20   packet_loss {loss:.6}\n\
             \x20 ]\n\
             ]",
            bd = self.bandwidth_down,
            bu = self.bandwidth_up,
            lat = self.latency_ms,
            loss = self.packet_loss,
        )
    }

    fn to_federated_pair_network(&self) -> Network {
        Network {
            graph: NetworkGraph {
                graph_type: "gml".to_owned(),
                inline: Some(self.to_federated_pair_gml()),
            },
        }
    }
}

#[derive(Serialize, Clone, Debug)]
struct ShadowConfig {
    general: General,
    network: Network,
    #[serde(skip_serializing_if = "Option::is_none")]
    experimental: Option<Experimental>,
    #[serde(skip_serializing_if = "Option::is_none")]
    host_option_defaults: Option<HostOptionDefaults>,
    hosts: BTreeMap<String, Host>,
}

#[derive(Serialize, Clone, Debug)]
struct General {
    stop_time: String,
    seed: u32,
    model_unblocked_syscall_latency: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    progress: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    data_directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    log_level: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
struct Experimental {
    scheduler: String,
    use_cpu_pinning: bool,
    use_worker_spinning: bool,
    native_preemption_enabled: bool,
    native_preemption_native_interval: String,
    native_preemption_sim_interval: String,
}

#[derive(Serialize, Clone, Debug)]
struct Network {
    graph: NetworkGraph,
}

#[derive(Serialize, Clone, Debug)]
struct NetworkGraph {
    #[serde(rename = "type")]
    graph_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    inline: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
struct HostOptionDefaults {
    #[serde(skip_serializing_if = "Option::is_none")]
    pcap_enabled: Option<bool>,
}

impl Default for HostOptionDefaults {
    fn default() -> Self {
        Self {
            pcap_enabled: Some(true),
        }
    }
}

#[derive(Serialize, Clone, Debug)]
struct Host {
    network_node_id: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    ip_addr: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    host_options: Option<HostOptions>,
    processes: Vec<Process>,
}

#[derive(Serialize, Clone, Debug)]
struct HostOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pcap_enabled: Option<bool>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(untagged)]
enum ProcessFinalState {
    Running(RunningVal),
    Exited { exited: i32 },
}

#[derive(Serialize, Clone, Debug)]
enum RunningVal {
    #[serde(rename = "running")]
    Running,
}

#[derive(Serialize, Clone, Debug)]
struct Process {
    path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    args: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    start_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expected_final_state: Option<ProcessFinalState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    environment: Option<BTreeMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    shutdown_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    shutdown_signal: Option<String>,
}

impl ShadowConfig {
    fn to_yaml(&self) -> Result<String> {
        serde_yaml::to_string(self).context("failed to serialize Shadow YAML")
    }
}

#[derive(Serialize, Clone, Debug)]
struct TuwunelConfig {
    global: TuwunelGlobal,
}

#[derive(Serialize, Clone, Debug)]
struct TuwunelGlobal {
    server_name: String,
    database_path: String,
    address: String,
    port: u16,
    allow_registration: bool,
    registration_token: String,
    log: String,
    startup_netburst: bool,
    allow_encryption: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    allow_federation: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    trusted_servers: Vec<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    allow_invalid_tls_certificates: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    tls: Option<TuwunelTls>,
}

#[derive(Serialize, Clone, Debug)]
struct TuwunelTls {
    certs: String,
    key: String,
}

impl TuwunelConfig {
    fn new(server_name: &str, database_path: &str) -> Self {
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

    fn with_federation(mut self, trusted_server: &str) -> Self {
        self.global.allow_federation = true;
        self.global.trusted_servers = vec![trusted_server.to_owned()];
        self.global.allow_invalid_tls_certificates = true;
        self
    }

    fn with_tls(mut self, cert_path: &str, key_path: &str) -> Self {
        self.global.tls = Some(TuwunelTls {
            certs: cert_path.to_owned(),
            key: key_path.to_owned(),
        });
        self
    }

    fn to_toml(&self) -> Result<String> {
        toml::to_string(self).context("failed to serialize Tuwunel TOML")
    }
}

struct ShadowArtifacts {
    tuwunel_bin: PathBuf,
    client_bin: PathBuf,
}

pub fn run_latency_message_scenario(seed: u32) -> Result<ShadowRun> {
    run_shadow_scenario(
        seed,
        SHADOW_CLIENT_SUBCOMMAND,
        SHADOW_STOP_TIME,
        ALICE_START_TIME,
        BOB_START_TIME,
    )
}

pub fn run_latency_encrypted_message_scenario(seed: u32) -> Result<ShadowRun> {
    run_shadow_scenario(
        seed,
        SHADOW_CLIENT_E2EE_SUBCOMMAND,
        SHADOW_E2EE_STOP_TIME,
        ALICE_E2EE_START_TIME,
        BOB_E2EE_START_TIME,
    )
}

pub fn run_multi_homeserver_message_scenario(seed: u32) -> Result<ShadowRun> {
    ensure_shadow_host_requirements()?;

    let workspace_root = workspace_root()?;
    let artifacts = build_shadow_binaries(&workspace_root, "shadow_features")?;
    let tempdir = tempfile::tempdir().context("failed to create Shadow tempdir")?;

    let (alice_cert, alice_key) =
        generate_self_signed_cert(tempdir.path(), ALICE_FEDERATED_HOST_NAME)?;
    let (bob_cert, bob_key) = generate_self_signed_cert(tempdir.path(), BOB_FEDERATED_HOST_NAME)?;

    let alice_config = TuwunelConfig::new(ALICE_FEDERATED_SERVER_NAME, "alice-data")
        .with_federation(BOB_FEDERATED_SERVER_NAME)
        .with_tls(&alice_cert, &alice_key);
    let alice_config_path = tempdir.path().join("alice-tuwunel.toml");
    fs::write(&alice_config_path, alice_config.to_toml()?).with_context(|| {
        format!(
            "failed to write generated Alice Tuwunel config to {}",
            alice_config_path.display()
        )
    })?;

    let bob_config = TuwunelConfig::new(BOB_FEDERATED_SERVER_NAME, "bob-data")
        .with_federation(ALICE_FEDERATED_SERVER_NAME)
        .with_tls(&bob_cert, &bob_key);
    let bob_config_path = tempdir.path().join("bob-tuwunel.toml");
    fs::write(&bob_config_path, bob_config.to_toml()?).with_context(|| {
        format!(
            "failed to write generated Bob Tuwunel config to {}",
            bob_config_path.display()
        )
    })?;

    let data_dir = tempdir.path().join(SHADOW_DATA_DIR_NAME);
    let topology = TopologyFixture::federated_pair();
    let shadow_config = multi_homeserver_config_with_topology(
        &artifacts.tuwunel_bin,
        &artifacts.client_bin,
        &alice_config_path,
        &bob_config_path,
        &data_dir,
        seed,
        &topology,
    );
    let shadow_config_path = tempdir.path().join("shadow-multi-homeserver.yaml");
    fs::write(&shadow_config_path, shadow_config.to_yaml()?).with_context(|| {
        format!(
            "failed to write generated multi-homeserver Shadow config to {}",
            shadow_config_path.display()
        )
    })?;

    let result = run_shadow(&shadow_config_path, seed, &data_dir)?;

    Ok(ShadowRun {
        _tempdir: tempdir,
        topology,
        shadow_config_path,
        tuwunel_config_path: alice_config_path,
        result,
    })
}

fn generate_self_signed_cert(dir: &Path, hostname: &str) -> Result<(String, String)> {
    let cert_path = dir.join(format!("{hostname}.crt"));
    let key_path = dir.join(format!("{hostname}.key"));

    let status = Command::new("openssl")
        .args([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            key_path.to_str().context("key path was not UTF-8")?,
            "-out",
            cert_path.to_str().context("cert path was not UTF-8")?,
            "-days",
            "1",
            "-nodes",
            "-subj",
            &format!("/CN={hostname}"),
        ])
        .status()
        .context("failed to run openssl for Shadow TLS certificate generation")?;

    if !status.success() {
        bail!("openssl failed while generating Shadow TLS certificate for {hostname}");
    }

    Ok((
        cert_path
            .to_str()
            .context("cert path was not UTF-8")?
            .to_owned(),
        key_path
            .to_str()
            .context("key path was not UTF-8")?
            .to_owned(),
    ))
}

fn run_shadow_scenario(
    seed: u32,
    subcommand: &str,
    stop_time: &str,
    alice_start: &str,
    bob_start: &str,
) -> Result<ShadowRun> {
    ensure_shadow_host_requirements()?;

    let workspace_root = workspace_root()?;
    let artifacts = build_shadow_binaries(&workspace_root, "shadow")?;
    let tempdir = tempfile::tempdir().context("failed to create Shadow tempdir")?;

    let tuwunel_config = TuwunelConfig::new(TUWUNEL_SERVER_NAME, TUWUNEL_DATABASE_PATH);
    let tuwunel_config_path = tempdir.path().join("tuwunel.toml");
    fs::write(&tuwunel_config_path, tuwunel_config.to_toml()?).with_context(|| {
        format!(
            "failed to write generated Tuwunel config to {}",
            tuwunel_config_path.display()
        )
    })?;

    let data_dir = tempdir.path().join(SHADOW_DATA_DIR_NAME);
    let topology = TopologyFixture::slow_mobile();
    let shadow_config = three_host_config_with_topology(
        &artifacts.tuwunel_bin,
        &artifacts.client_bin,
        &tuwunel_config_path,
        &data_dir,
        subcommand,
        stop_time,
        seed,
        alice_start,
        bob_start,
        &topology,
    );
    let shadow_config_path = tempdir.path().join("shadow.yaml");
    fs::write(&shadow_config_path, shadow_config.to_yaml()?).with_context(|| {
        format!(
            "failed to write generated Shadow config to {}",
            shadow_config_path.display()
        )
    })?;

    let result = run_shadow(&shadow_config_path, seed, &data_dir)?;

    Ok(ShadowRun {
        _tempdir: tempdir,
        topology,
        shadow_config_path,
        tuwunel_config_path,
        result,
    })
}

fn ensure_shadow_host_requirements() -> Result<()> {
    if !cfg!(target_os = "linux") {
        bail!("Shadow tests require a Linux host");
    }

    if let Ok(status) = fs::read_to_string("/proc/self/status") {
        if let Some(line) = status.lines().find(|line| line.starts_with("Seccomp:")) {
            if let Some(mode) = line.split_whitespace().nth(1) {
                if mode == "2" {
                    bail!(
                        "Shadow tests detected seccomp filtering (Seccomp: 2).\n\
                         Shadow requires `seccomp=unconfined` when executed inside Docker or another restricted container.\n\
                         If running in Docker, add: `--security-opt seccomp=unconfined`."
                    );
                }
            }
        }
    }

    let rustc_output = Command::new("rustc")
        .arg("-vV")
        .output()
        .context("failed to execute `rustc -vV`")?;
    let rustc_stdout = String::from_utf8_lossy(&rustc_output.stdout);
    if !rustc_stdout.contains("host: x86_64-unknown-linux-gnu") {
        bail!(
            "Shadow tests require host target x86_64-unknown-linux-gnu; got:\n{}",
            rustc_stdout
        );
    }

    run_command(
        Command::new("shadow").arg("--version"),
        "confirm Shadow installation",
    )?;

    Ok(())
}

fn workspace_root() -> Result<PathBuf> {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .context("failed to determine workspace root")
}

fn build_shadow_binaries(workspace_root: &Path, tuwunel_features: &str) -> Result<ShadowArtifacts> {
    let client_bin = build_shadow_client_binary(workspace_root)?;
    let tuwunel_bin = build_tuwunel_binary(workspace_root, tuwunel_features)?;

    ensure_dynamically_linked(&client_bin)?;
    ensure_dynamically_linked(&tuwunel_bin)?;

    Ok(ShadowArtifacts {
        tuwunel_bin,
        client_bin,
    })
}

fn build_shadow_client_binary(workspace_root: &Path) -> Result<PathBuf> {
    run_command(
        Command::new("cargo").current_dir(workspace_root).args([
            "build",
            "--profile",
            "shadow",
            "-p",
            "shadow-client",
        ]),
        "build shadow-client",
    )?;

    let binary_path = workspace_root.join("target/shadow/shadow-client");
    if !binary_path.exists() {
        bail!(
            "shadow-client binary was not produced at {}",
            binary_path.display()
        );
    }

    Ok(binary_path)
}

fn build_tuwunel_binary(workspace_root: &Path, features: &str) -> Result<PathBuf> {
    let checkout_root = discover_tuwunel_checkout_root(workspace_root)?;

    run_command(
        Command::new("cargo").current_dir(&checkout_root).args([
            "build",
            "--profile",
            "shadow",
            "-p",
            "tuwunel",
            "--no-default-features",
            "--features",
            features,
        ]),
        "build upstream tuwunel shadow binary",
    )?;

    let binary_path = checkout_root.join("target/shadow/tuwunel");
    if !binary_path.exists() {
        bail!(
            "tuwunel binary was not produced at {}",
            binary_path.display()
        );
    }

    Ok(binary_path)
}

fn discover_tuwunel_checkout_root(workspace_root: &Path) -> Result<PathBuf> {
    if let Ok(override_root) = std::env::var("TUWUNEL_CHECKOUT_ROOT") {
        let override_root = PathBuf::from(override_root);
        let override_root = override_root.canonicalize().with_context(|| {
            format!("failed to canonicalize TUWUNEL_CHECKOUT_ROOT={override_root:?}")
        })?;

        let tuwunel_manifest = override_root.join("src/main/Cargo.toml");
        if !tuwunel_manifest.exists() {
            bail!(
                "TUWUNEL_CHECKOUT_ROOT={} does not contain src/main/Cargo.toml",
                override_root.display()
            );
        }

        return Ok(override_root);
    }

    let output = Command::new("cargo")
        .current_dir(workspace_root)
        .args(["metadata", "--format-version", "1"])
        .output()
        .context("failed to execute `cargo metadata`")?;

    if !output.status.success() {
        bail!(
            "cargo metadata failed while locating tuwunel checkout\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).context("failed to parse cargo metadata JSON")?;
    let packages = metadata["packages"]
        .as_array()
        .context("cargo metadata missing packages array")?;

    let manifest_path = packages
        .iter()
        .find(|package| package["name"].as_str() == Some("tuwunel-embed"))
        .and_then(|package| package["manifest_path"].as_str())
        .context("failed to locate tuwunel-embed manifest in cargo metadata")?;

    let manifest_path = PathBuf::from(manifest_path);
    let mut cursor = manifest_path
        .parent()
        .context("tuwunel-embed manifest path had no parent directory")?;

    loop {
        let candidate = cursor.to_path_buf();
        let tuwunel_manifest = candidate.join("src/main/Cargo.toml");
        if tuwunel_manifest.exists() {
            return Ok(candidate);
        }

        if candidate == workspace_root {
            break;
        }

        cursor = cursor.parent().context(
            "failed to derive tuwunel checkout root from manifest path (reached filesystem root)",
        )?;
    }

    bail!(
        "failed to locate tuwunel checkout root from cargo metadata.\n\
         Expected to find src/main/Cargo.toml while walking upward from {}\n\
         If tuwunel is checked out elsewhere, set TUWUNEL_CHECKOUT_ROOT=/path/to/tuwunel.",
        manifest_path.display()
    )
}

fn ensure_dynamically_linked(binary_path: &Path) -> Result<()> {
    let output = Command::new("ldd")
        .arg(binary_path)
        .output()
        .with_context(|| format!("failed to execute `ldd` for {}", binary_path.display()))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() || stdout.contains("not a dynamic executable") {
        bail!(
            "Shadow requires a dynamically linked binary for {}.\nstdout:\n{}\nstderr:\n{}",
            binary_path.display(),
            stdout,
            stderr,
        );
    }

    Ok(())
}

fn run_command(command: &mut Command, description: &str) -> Result<()> {
    let output = command
        .output()
        .with_context(|| format!("failed to {description}"))?;

    if output.status.success() {
        return Ok(());
    }

    bail!(
        "failed to {description}\nstatus: {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}

fn run_shadow(config_path: &Path, seed: u32, data_dir: &Path) -> Result<ShadowResult> {
    if data_dir.exists() {
        let _ = fs::remove_dir_all(data_dir);
    }

    let output = Command::new("shadow")
        .arg("--parallelism")
        .arg("1")
        .arg("--seed")
        .arg(seed.to_string())
        .arg("--data-directory")
        .arg(data_dir)
        .arg(config_path)
        .output()
        .with_context(|| {
            format!(
                "failed to execute shadow with config {}",
                config_path.display()
            )
        })?;

    let result = ShadowResult {
        exit_code: output.status.code().unwrap_or(-1),
        data_dir: data_dir.to_path_buf(),
        seed,
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    };

    if !result.success() {
        result.print_failure_diagnostics();
    }

    Ok(result)
}

fn glob_files(dir: &Path, extension: &str) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };

    let mut files: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == extension))
        .collect();
    files.sort();
    files
}

#[expect(clippy::too_many_arguments)]
fn three_host_config_with_topology(
    tuwunel_bin: &Path,
    client_bin: &Path,
    config_path: &Path,
    data_dir: &Path,
    subcommand: &str,
    stop_time: &str,
    seed: u32,
    alice_start: &str,
    bob_start: &str,
    topology: &TopologyFixture,
) -> ShadowConfig {
    let mut server_env = BTreeMap::new();
    server_env.insert(
        "TUWUNEL_CONFIG".to_owned(),
        config_path.to_string_lossy().into_owned(),
    );
    server_env.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

    let mut hosts = BTreeMap::new();
    hosts.insert(
        "tuwunel-server".to_owned(),
        Host {
            network_node_id: 0,
            ip_addr: None,
            host_options: None,
            processes: vec![Process {
                path: tuwunel_bin.to_string_lossy().into_owned(),
                args: None,
                start_time: Some("1s".to_owned()),
                expected_final_state: Some(ProcessFinalState::Running(RunningVal::Running)),
                environment: Some(server_env),
                shutdown_time: None,
                shutdown_signal: Some("SIGTERM".to_owned()),
            }],
        },
    );
    hosts.insert(
        "alice-host".to_owned(),
        Host {
            network_node_id: 0,
            ip_addr: None,
            host_options: None,
            processes: vec![Process {
                path: client_bin.to_string_lossy().into_owned(),
                args: Some(format!(
                    "{subcommand} --server-url http://{TUWUNEL_SERVER_NAME}:8448 --role alice"
                )),
                start_time: Some(alice_start.to_owned()),
                expected_final_state: Some(ProcessFinalState::Exited { exited: 0 }),
                environment: None,
                shutdown_time: None,
                shutdown_signal: None,
            }],
        },
    );
    hosts.insert(
        "bob-host".to_owned(),
        Host {
            network_node_id: 0,
            ip_addr: None,
            host_options: None,
            processes: vec![Process {
                path: client_bin.to_string_lossy().into_owned(),
                args: Some(format!(
                    "{subcommand} --server-url http://{TUWUNEL_SERVER_NAME}:8448 --role bob"
                )),
                start_time: Some(bob_start.to_owned()),
                expected_final_state: Some(ProcessFinalState::Exited { exited: 0 }),
                environment: None,
                shutdown_time: None,
                shutdown_signal: None,
            }],
        },
    );

    ShadowConfig {
        general: General {
            stop_time: stop_time.to_owned(),
            seed,
            model_unblocked_syscall_latency: true,
            progress: None,
            data_directory: Some(data_dir.to_string_lossy().into_owned()),
            log_level: Some("info".to_owned()),
        },
        network: topology.to_network(),
        experimental: Some(Experimental {
            scheduler: "thread-per-host".to_owned(),
            use_cpu_pinning: false,
            use_worker_spinning: false,
            native_preemption_enabled: true,
            native_preemption_native_interval: "10 ms".to_owned(),
            native_preemption_sim_interval: "10 ms".to_owned(),
        }),
        host_option_defaults: Some(HostOptionDefaults::default()),
        hosts,
    }
}

fn tuwunel_host(tuwunel_bin: &Path, config_path: &Path) -> Host {
    let mut server_env = BTreeMap::new();
    server_env.insert(
        "TUWUNEL_CONFIG".to_owned(),
        config_path.to_string_lossy().into_owned(),
    );
    server_env.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());
    server_env.insert(
        "TUWUNEL_SHADOW_HOSTS".to_owned(),
        format!(
            "{ALICE_FEDERATED_HOST_NAME}={ALICE_FEDERATED_HOST_IP},{BOB_FEDERATED_HOST_NAME}={BOB_FEDERATED_HOST_IP}"
        ),
    );

    Host {
        network_node_id: 0,
        ip_addr: None,
        host_options: None,
        processes: vec![Process {
            path: tuwunel_bin.to_string_lossy().into_owned(),
            args: None,
            start_time: Some("1s".to_owned()),
            expected_final_state: Some(ProcessFinalState::Running(RunningVal::Running)),
            environment: Some(server_env),
            shutdown_time: None,
            shutdown_signal: Some("SIGTERM".to_owned()),
        }],
    }
}

fn shadow_client_host(
    client_bin: &Path,
    subcommand: &str,
    server_name: &str,
    role: &str,
    start_time: &str,
    network_node_id: u32,
) -> Host {
    Host {
        network_node_id,
        ip_addr: None,
        host_options: None,
        processes: vec![Process {
            path: client_bin.to_string_lossy().into_owned(),
            args: Some(format!(
                "{subcommand} --server-url http://{server_name}:8448 --role {role}"
            )),
            start_time: Some(start_time.to_owned()),
            expected_final_state: Some(ProcessFinalState::Exited { exited: 0 }),
            environment: None,
            shutdown_time: None,
            shutdown_signal: None,
        }],
    }
}

fn multi_homeserver_config_with_topology(
    tuwunel_bin: &Path,
    client_bin: &Path,
    alice_config_path: &Path,
    bob_config_path: &Path,
    data_dir: &Path,
    seed: u32,
    topology: &TopologyFixture,
) -> ShadowConfig {
    let mut hosts = BTreeMap::new();
    hosts.insert(
        ALICE_FEDERATED_HOST_NAME.to_owned(),
        Host {
            network_node_id: 0,
            ip_addr: Some(ALICE_FEDERATED_HOST_IP.to_owned()),
            ..tuwunel_host(tuwunel_bin, alice_config_path)
        },
    );
    hosts.insert(
        BOB_FEDERATED_HOST_NAME.to_owned(),
        Host {
            network_node_id: 1,
            ip_addr: Some(BOB_FEDERATED_HOST_IP.to_owned()),
            ..tuwunel_host(tuwunel_bin, bob_config_path)
        },
    );
    hosts.insert(
        "alice-host".to_owned(),
        shadow_client_host(
            client_bin,
            SHADOW_CLIENT_FEDERATED_SUBCOMMAND,
            ALICE_FEDERATED_HOST_NAME,
            "alice",
            ALICE_START_TIME,
            0,
        ),
    );
    hosts.insert(
        "bob-host".to_owned(),
        shadow_client_host(
            client_bin,
            SHADOW_CLIENT_FEDERATED_SUBCOMMAND,
            BOB_FEDERATED_HOST_NAME,
            "bob",
            BOB_START_TIME,
            1,
        ),
    );

    ShadowConfig {
        general: General {
            stop_time: FEDERATED_SHADOW_STOP_TIME.to_owned(),
            seed,
            model_unblocked_syscall_latency: true,
            progress: None,
            data_directory: Some(data_dir.to_string_lossy().into_owned()),
            log_level: Some("info".to_owned()),
        },
        network: topology.to_federated_pair_network(),
        experimental: Some(Experimental {
            scheduler: "thread-per-host".to_owned(),
            use_cpu_pinning: false,
            use_worker_spinning: false,
            native_preemption_enabled: true,
            native_preemption_native_interval: "10 ms".to_owned(),
            native_preemption_sim_interval: "10 ms".to_owned(),
        }),
        host_option_defaults: Some(HostOptionDefaults::default()),
        hosts,
    }
}
