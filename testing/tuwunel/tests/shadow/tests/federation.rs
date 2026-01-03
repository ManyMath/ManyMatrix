use std::{collections::BTreeMap, path::PathBuf, process::Command};

use shadow_test_harness::{
	config::{
		shadow::{
			General, Host, HostOptionDefaults, Process,
			ProcessFinalState, RunningVal, ShadowConfig,
			TopologyFixture,
		},
		tuwunel::TuwunelConfig,
	},
	runner::run_shadow,
};

/// Build tuwunel and matrix-test-client with the shadow profile.
fn build_shadow_binaries() -> (PathBuf, PathBuf) {
	let workspace_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
		.join("../..")
		.canonicalize()
		.expect("failed to find workspace root");

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
	assert!(
		status.success(),
		"Failed to build tuwunel with shadow profile"
	);

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
	assert!(
		status.success(),
		"Failed to build matrix-test-client with shadow profile"
	);

	let tuwunel_bin = workspace_root.join("target/shadow/tuwunel");
	let client_bin =
		workspace_root.join("target/shadow/matrix-test-client");

	assert!(
		tuwunel_bin.exists(),
		"tuwunel binary not found at {}",
		tuwunel_bin.display()
	);
	assert!(
		client_bin.exists(),
		"matrix-test-client not found at {}",
		client_bin.display()
	);

	(tuwunel_bin, client_bin)
}

// Wall-clock time is dominated by Shadow syscall interception overhead,
// not scenario duration. Two servers with RocksDB can take 60-120 min
// on an 8-core machine despite the scenario completing in <60s simulated.
#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test federation -- --ignored
fn shadow_federation() {
	let (tuwunel_bin, client_bin) = build_shadow_binaries();

	let tmp =
		tempfile::tempdir().expect("failed to create tempdir");

	let config_a = TuwunelConfig::new("server-a", "data")
		.with_federation("server-b:8448", true);
	let config_b = TuwunelConfig::new("server-b", "data")
		.with_federation("server-a:8448", true);

	let config_a_path = tmp.path().join("tuwunel-a.toml");
	let config_b_path = tmp.path().join("tuwunel-b.toml");
	std::fs::write(
		&config_a_path,
		config_a.to_toml().expect("serialize config A"),
	)
	.expect("write config A");
	std::fs::write(
		&config_b_path,
		config_b.to_toml().expect("serialize config B"),
	)
	.expect("write config B");

	let topology = TopologyFixture::federation(50, 0.0);

	let tuwunel_path = tuwunel_bin
		.to_str()
		.expect("tuwunel_bin must be valid UTF-8")
		.to_owned();
	let client_path = client_bin
		.to_str()
		.expect("client_bin must be valid UTF-8")
		.to_owned();
	let config_a_str = config_a_path
		.to_str()
		.expect("config path must be valid UTF-8")
		.to_owned();
	let config_b_str = config_b_path
		.to_str()
		.expect("config path must be valid UTF-8")
		.to_owned();
	let data_str = tmp
		.path()
		.join("shadow.data")
		.to_str()
		.expect("data dir must be valid UTF-8")
		.to_owned();

	let mut env_a = BTreeMap::new();
	env_a.insert("TUWUNEL_CONFIG".to_owned(), config_a_str);
	env_a.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let mut env_b = BTreeMap::new();
	env_b.insert("TUWUNEL_CONFIG".to_owned(), config_b_str);
	env_b.insert("TUWUNEL_LOG".to_owned(), "info".to_owned());

	let mut hosts = BTreeMap::new();

	hosts.insert(
		"server-a".to_owned(),
		Host {
			network_node_id: 0,
			host_options: None,
			processes: vec![Process {
				path: tuwunel_path.clone(),
				args: None,
				start_time: Some("1s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Running(RunningVal::Running),
				),
				environment: Some(env_a),
				shutdown_time: None,
				shutdown_signal: Some("SIGTERM".to_owned()),
			}],
		},
	);

	hosts.insert(
		"server-b".to_owned(),
		Host {
			network_node_id: 1,
			host_options: None,
			processes: vec![Process {
				path: tuwunel_path,
				args: None,
				start_time: Some("1s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Running(RunningVal::Running),
				),
				environment: Some(env_b),
				shutdown_time: None,
				shutdown_signal: Some("SIGTERM".to_owned()),
			}],
		},
	);

	hosts.insert(
		"creator-host".to_owned(),
		Host {
			network_node_id: 0,
			host_options: None,
			processes: vec![Process {
				path: client_path.clone(),
				args: Some(
					"federation --server-url \
					 http://server-a:8448 --role creator"
						.to_owned(),
				),
				start_time: Some("10s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Exited { exited: 0 },
				),
				environment: None,
				shutdown_time: None,
				shutdown_signal: None,
			}],
		},
	);

	hosts.insert(
		"joiner-host".to_owned(),
		Host {
			network_node_id: 1,
			host_options: None,
			processes: vec![Process {
				path: client_path,
				args: Some(
					"federation --server-url \
					 http://server-b:8448 --role joiner"
						.to_owned(),
				),
				start_time: Some("15s".to_owned()),
				expected_final_state: Some(
					ProcessFinalState::Exited { exited: 0 },
				),
				environment: None,
				shutdown_time: None,
				shutdown_signal: None,
			}],
		},
	);

	let shadow_config = ShadowConfig {
		general: General {
			stop_time: "60s".to_owned(),
			seed: 42,
			model_unblocked_syscall_latency: true,
			data_directory: Some(data_str),
			log_level: Some("info".to_owned()),
		},
		network: topology.to_federation_network(),
		host_option_defaults: Some(HostOptionDefaults::default()),
		hosts,
	};

	let shadow_yaml = shadow_config
		.to_yaml()
		.expect("failed to serialize shadow config");
	let shadow_yaml_path = tmp.path().join("shadow.yaml");
	std::fs::write(&shadow_yaml_path, &shadow_yaml)
		.expect("failed to write shadow config");

	let data_dir = tmp.path().join("shadow.data");
	let result =
		run_shadow(&shadow_yaml_path, 42, Some(&data_dir), None);

	assert!(
		result.success(),
		"Shadow federation test failed with exit code {}.\n\
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

	let server_a_stdouts =
		result.find_host_stdouts("server-a");
	assert!(
		!server_a_stdouts.is_empty(),
		"No stdout files for server-a"
	);

	let server_b_stdouts =
		result.find_host_stdouts("server-b");
	assert!(
		!server_b_stdouts.is_empty(),
		"No stdout files for server-b"
	);

	eprintln!(
		"Shadow federation test PASSED (seed={})",
		result.seed
	);
}
