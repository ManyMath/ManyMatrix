use shadow_test_harness::{
	config::{
		shadow::{load_test_config, TopologyFixture},
		tuwunel::TuwunelConfig,
	},
	runner::run_shadow,
};

mod common;

#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test load -- --ignored
fn shadow_load_100_clients() {
	let (tuwunel_bin, client_bin) =
		common::build_shadow_binaries();
	let tmp =
		tempfile::tempdir().expect("failed to create tempdir");

	let tuwunel_config =
		TuwunelConfig::new("tuwunel-server", "data");
	let config_toml = tuwunel_config
		.to_toml()
		.expect("failed to serialize tuwunel config");
	let config_path = tmp.path().join("tuwunel.toml");
	std::fs::write(&config_path, &config_toml)
		.expect("failed to write tuwunel config");

	// Minimal latency, no loss: isolate server load from network effects.
	let topology = TopologyFixture::high_latency()
		.with_latency(1)
		.with_loss(0.0);

	let data_dir = tmp.path().join("shadow.data");

	// 600s: generous for 100 sequential registrations under
	// simulated time.
	let shadow_config = load_test_config(
		&tuwunel_bin,
		&client_bin,
		&config_path,
		&data_dir,
		100,
		&topology,
		"600s",
		42,
	);

	let shadow_yaml = shadow_config
		.to_yaml()
		.expect("failed to serialize shadow config");
	let shadow_yaml_path = tmp.path().join("shadow.yaml");
	std::fs::write(&shadow_yaml_path, &shadow_yaml)
		.expect("failed to write shadow config");

	let result = run_shadow(
		&shadow_yaml_path,
		42,
		Some(&data_dir),
		None,
	);

	// Shadow exit 0 means all processes met expected_final_state.
	assert!(
		result.success(),
		"Shadow load test failed with exit code {}.\n\
		 Seed: {}\nData dir: {}\n\
		 Shadow stdout:\n{}\nShadow stderr:\n{}",
		result.exit_code,
		result.seed,
		result.data_dir.display(),
		result.stdout,
		result.stderr,
	);

	// Verify creator client completed.
	let creator_stderrs =
		result.find_host_stderrs("client-001");
	assert!(
		!creator_stderrs.is_empty(),
		"No stderr files found for client-001"
	);
	let creator_stderr =
		std::fs::read_to_string(&creator_stderrs[0])
			.expect("failed to read client-001 stderr");
	assert!(
		creator_stderr.contains(
			"load-test creator scenario complete"
		),
		"client-001 did not complete creator flow.\n\
		 Stderr:\n{creator_stderr}"
	);

	// Spot-check a few joiner clients.
	for client_num in [2u32, 50, 100] {
		let hostname = format!("client-{client_num:03}");
		let stderrs =
			result.find_host_stderrs(&hostname);
		assert!(
			!stderrs.is_empty(),
			"No stderr files found for {hostname}"
		);
		let stderr =
			std::fs::read_to_string(&stderrs[0])
				.unwrap_or_else(|_| {
					panic!(
						"failed to read {hostname} \
						 stderr"
					)
				});
		assert!(
			stderr.contains(
				"load-test joiner scenario complete"
			),
			"{hostname} did not complete joiner flow.\n\
			 Stderr:\n{stderr}"
		);
	}

	eprintln!(
		"Shadow load test PASSED: 100 clients completed \
		 (seed={})",
		result.seed,
	);
}
