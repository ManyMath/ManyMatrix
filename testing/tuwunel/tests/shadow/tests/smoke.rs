use std::{collections::BTreeMap, path::PathBuf, process::Command};

use shadow_test_harness::{
	config::{
		shadow::{
			General, Host, HostOptionDefaults, Network, Process, ProcessFinalState,
			RunningVal, ShadowConfig,
		},
		tuwunel::TuwunelConfig,
	},
	runner::run_shadow,
};

/// Build tuwunel and matrix-test-client with the shadow profile.
/// This is slow (release build) but ensures binaries are available.
fn build_shadow_binaries() -> (PathBuf, PathBuf) {
	let workspace_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
		.join("../..")
		.canonicalize()
		.expect("failed to find workspace root");

	// Build tuwunel with shadow profile
	let status = Command::new("cargo")
		.current_dir(&workspace_root)
		.args([
			"build",
			"--profile",
			"shadow",
			"--no-default-features",
			"--features",
			"shadow_features",
		])
		.status()
		.expect("failed to run cargo build for tuwunel");
	assert!(status.success(), "Failed to build tuwunel with shadow profile");

	// Build matrix-test-client with shadow profile
	let status = Command::new("cargo")
		.current_dir(&workspace_root)
		.args([
			"build",
			"--profile",
			"shadow",
			"-p",
			"shadow-test-harness",
			"--bin",
			"matrix-test-client",
		])
		.status()
		.expect("failed to run cargo build for matrix-test-client");
	assert!(status.success(), "Failed to build matrix-test-client with shadow profile");

	let tuwunel_bin = workspace_root.join("target/shadow/tuwunel");
	let client_bin = workspace_root.join("target/shadow/matrix-test-client");

	assert!(tuwunel_bin.exists(), "tuwunel binary not found at {}", tuwunel_bin.display());
	assert!(client_bin.exists(), "matrix-test-client not found at {}", client_bin.display());

	(tuwunel_bin, client_bin)
}

#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test smoke -- --ignored
fn shadow_smoke() {
	let (tuwunel_bin, client_bin) = build_shadow_binaries();

	let tmp = tempfile::tempdir().expect("failed to create tempdir");

	let tuwunel_config = TuwunelConfig::new("tuwunel-server", "data");
	let config_toml = tuwunel_config
		.to_toml()
		.expect("failed to serialize tuwunel config");
	let config_path = tmp.path().join("tuwunel.toml");
	std::fs::write(&config_path, &config_toml).expect("failed to write tuwunel config");

	let mut hosts = BTreeMap::new();

	let mut server_env = BTreeMap::new();
	server_env.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());
	server_env.insert(
		"TUWUNEL_CONFIG".to_owned(),
		config_path
			.to_str()
			.expect("config path not valid UTF-8")
			.to_owned(),
	);

	hosts.insert(
		"tuwunel-server".to_owned(),
		Host {
			network_node_id: 0,
			host_options: None,
			processes: vec![Process {
				path: tuwunel_bin
					.to_str()
					.expect("binary path not valid UTF-8")
					.to_owned(),
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
		"test-client".to_owned(),
		Host {
			network_node_id: 0,
			host_options: None,
			processes: vec![Process {
				path: client_bin
					.to_str()
					.expect("binary path not valid UTF-8")
					.to_owned(),
				args: Some(
					"smoke --server-url \
					 http://tuwunel-server:8448"
						.to_owned(),
				),
				start_time: Some("5s".to_owned()),
				expected_final_state: Some(ProcessFinalState::Exited { exited: 0 }),
				environment: None,
				shutdown_time: None,
				shutdown_signal: None,
			}],
		},
	);

	let shadow_config = ShadowConfig {
		general: General {
			data_directory: Some(
				tmp.path()
					.join("shadow.data")
					.to_str()
					.expect("data dir path not valid UTF-8")
					.to_owned(),
			),
			..Default::default()
		},
		network: Network::default(),
		host_option_defaults: Some(HostOptionDefaults::default()),
		hosts,
	};

	let shadow_yaml = shadow_config
		.to_yaml()
		.expect("failed to serialize shadow config");
	let shadow_yaml_path = tmp.path().join("shadow.yaml");
	std::fs::write(&shadow_yaml_path, &shadow_yaml).expect("failed to write shadow config");

	let data_dir = tmp.path().join("shadow.data");
	let result = run_shadow(&shadow_yaml_path, 42, Some(&data_dir), None);

	assert!(
		result.success(),
		"Shadow smoke test failed with exit code {}.\n\
		 Seed: {}\n\
		 Data dir: {}\n\
		 Shadow stdout:\n{}\n\
		 Shadow stderr:\n{}",
		result.exit_code,
		result.seed,
		result.data_dir.display(),
		result.stdout,
		result.stderr,
	);

	let server_stdouts = result.find_host_stdouts("tuwunel-server");
	assert!(!server_stdouts.is_empty(), "No stdout files found for tuwunel-server host");

	let client_stdouts = result.find_host_stdouts("test-client");
	assert!(!client_stdouts.is_empty(), "No stdout files found for test-client host");

	// Confirm the test client observed server readiness
	let client_stderrs = result.find_host_stderrs("test-client");
	assert!(!client_stderrs.is_empty(), "No stderr files found for test-client host");
	let client_stderr_content =
		std::fs::read_to_string(&client_stderrs[0]).expect("failed to read client stderr");
	assert!(
		client_stderr_content.contains("Server ready"),
		"Test client did not report server ready. Client \
		 stderr:\n{}",
		client_stderr_content,
	);

	eprintln!("Shadow smoke test PASSED (seed={})", result.seed);
}
