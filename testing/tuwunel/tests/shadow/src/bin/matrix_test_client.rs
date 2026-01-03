use std::process::ExitCode;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "matrix-test-client")]
#[command(about = "Test client for Shadow simulation of tuwunel")]
struct Cli {
	#[command(subcommand)]
	command: Commands,
}

#[derive(Subcommand)]
enum Commands {
	/// Smoke test: verify server responds to
	/// /_matrix/client/versions
	Smoke {
		/// Base URL of the tuwunel server (e.g.,
		/// http://tuwunel-server:8448)
		#[arg(long)]
		server_url: String,

		/// Maximum number of retry attempts for server readiness
		#[arg(long, default_value_t = 60)]
		max_retries: u32,

		/// Milliseconds between retry attempts
		#[arg(long, default_value_t = 500)]
		retry_interval_ms: u64,
	},

	/// CS API test: register, login, create room, send message,
	/// sync
	CsApi {
		/// Base URL of the tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role for this client process ("alice" or "bob")
		#[arg(long)]
		role: String,
	},

	/// E2EE messaging: key upload, claim, encrypted message
	/// exchange
	E2eeMessaging {
		/// Base URL of the tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role for this client process ("alice" or "bob")
		#[arg(long)]
		role: String,
	},

	/// SAS verification between two devices
	SasVerify {
		/// Base URL of the tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role for this client process ("alice" or "bob")
		#[arg(long)]
		role: String,
	},

	/// Federation test: creator/joiner cross-server messaging
	Federation {
		/// Base URL of the tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role for this client process ("creator" or "joiner")
		#[arg(long)]
		role: String,
	},

	/// Load test: register, login, join room, send message
	LoadTest {
		/// Base URL of the tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role for this client process ("creator" or "joiner")
		#[arg(long)]
		role: String,

		/// Client ID (e.g., "001", "002")
		#[arg(long)]
		client_id: String,
	},

	/// Resilience test: server restart data persistence
	Resilience {
		/// Base URL of the tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role: "writer" or "verifier"
		#[arg(long)]
		role: String,
	},

	/// Partition test: federation survives server downtime
	Partition {
		/// Base URL of the local tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role: "creator", "survivor", or "verifier"
		#[arg(long)]
		role: String,

		/// Remote server name (e.g., "server2")
		#[arg(long)]
		remote_server: Option<String>,

		/// Remote server URL (e.g., "http://server2:8448")
		#[arg(long)]
		remote_url: Option<String>,
	},

	/// Re-sync test: federation catch-up after downtime
	Resync {
		/// Base URL of the local tuwunel server
		#[arg(long)]
		server_url: String,

		/// Role: "creator", "survivor", or "verifier"
		#[arg(long)]
		role: String,

		/// Remote server name (e.g., "server2")
		#[arg(long)]
		remote_server: Option<String>,

		/// Remote server URL (e.g., "http://server2:8448")
		#[arg(long)]
		remote_url: Option<String>,
	},
}

fn main() -> ExitCode {
	let cli = Cli::parse();

	match cli.command {
		| Commands::Smoke {
			server_url,
			max_retries,
			retry_interval_ms,
		} => run_in_runtime(run_smoke(
			&server_url,
			max_retries,
			retry_interval_ms,
		)),
		| Commands::CsApi { server_url, role } =>
			run_in_runtime(run_cs_api(&server_url, &role)),
		| Commands::E2eeMessaging { server_url, role } =>
			run_in_runtime(run_e2ee_messaging(
				&server_url, &role,
			)),
		| Commands::SasVerify { server_url, role } =>
			run_in_runtime(run_sas_verify(&server_url, &role)),
		| Commands::Federation { server_url, role } =>
			run_in_runtime(run_federation(
				&server_url, &role,
			)),
		| Commands::LoadTest {
			server_url,
			role,
			client_id,
		} => run_in_runtime(run_load_test(
			&server_url,
			&role,
			&client_id,
		)),
		| Commands::Resilience { server_url, role } =>
			run_in_runtime(run_resilience(
				&server_url, &role,
			)),
		| Commands::Partition {
			server_url,
			role,
			remote_server,
			remote_url,
		} => run_in_runtime(run_partition(
			&server_url,
			&role,
			remote_server.as_deref(),
			remote_url.as_deref(),
		)),
		| Commands::Resync {
			server_url,
			role,
			remote_server,
			remote_url,
		} => run_in_runtime(run_resync(
			&server_url,
			&role,
			remote_server.as_deref(),
			remote_url.as_deref(),
		)),
	}
}

/// Run an async function in a single-threaded tokio runtime.
fn run_in_runtime(
	future: impl std::future::Future<
		Output = Result<(), Box<dyn std::error::Error>>,
	>,
) -> ExitCode {
	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("failed to build tokio runtime");

	match rt.block_on(future) {
		| Ok(()) => ExitCode::SUCCESS,
		| Err(e) => {
			eprintln!("Test failed: {e}");
			ExitCode::FAILURE
		},
	}
}

async fn run_smoke(
	base_url: &str,
	max_retries: u32,
	retry_interval_ms: u64,
) -> Result<(), Box<dyn std::error::Error>> {
	let client = reqwest::Client::builder()
		.timeout(std::time::Duration::from_secs(5))
		.danger_accept_invalid_certs(true)
		.build()?;

	let url = format!("{base_url}/_matrix/client/versions");
	let interval = std::time::Duration::from_millis(retry_interval_ms);

	for attempt in 0..max_retries {
		match client.get(&url).send().await {
			| Ok(resp) if resp.status().is_success() => {
				let body = resp.text().await?;
				let json: serde_json::Value =
					serde_json::from_str(&body)?;
				if json.get("versions").is_some() {
					eprintln!(
						"Server ready after {attempt} retries. \
						 Versions: {body}"
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

async fn run_cs_api(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::cs_api::run_cs_api(
		server_url, role,
	)
	.await
}

async fn run_e2ee_messaging(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::e2ee_msg::run_e2ee_messaging(
		server_url, role,
	)
	.await
}

async fn run_sas_verify(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::sas_verify::run_sas_verify(
		server_url, role,
	)
	.await
}

async fn run_federation(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::federation::run_federation(
		server_url, role,
	)
	.await
}

async fn run_load_test(
	server_url: &str,
	role: &str,
	client_id: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::load_test::run_load_test(
		server_url, role, client_id,
	)
	.await
}

async fn run_resilience(
	server_url: &str,
	role: &str,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::resilience::run_resilience(
		server_url, role,
	)
	.await
}

async fn run_partition(
	server_url: &str,
	role: &str,
	remote_server: Option<&str>,
	remote_url: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::partition::run_partition(
		server_url,
		role,
		remote_server,
		remote_url,
	)
	.await
}

async fn run_resync(
	server_url: &str,
	role: &str,
	remote_server: Option<&str>,
	remote_url: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
	shadow_test_harness::scenarios::resync::run_resync(
		server_url,
		role,
		remote_server,
		remote_url,
	)
	.await
}
