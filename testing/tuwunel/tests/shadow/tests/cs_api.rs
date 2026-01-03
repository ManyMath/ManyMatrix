//! CS API integration test via Shadow simulation.
//!
//! Runs alice and bob on separate Shadow hosts against a tuwunel
//! server. Alice creates a room, sends a message; bob joins and
//! verifies receipt.
//!
//! Run with: cargo test -p shadow-test-harness --test cs_api -- --ignored

mod common;

use shadow_test_harness::{
	config::{shadow::three_host_config, tuwunel::TuwunelConfig},
	runner::run_shadow,
};

#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test cs_api -- --ignored
fn shadow_cs_api() {
	let (tuwunel_bin, client_bin) =
		common::build_shadow_binaries();

	let tmp = tempfile::tempdir()
		.expect("failed to create tempdir");

	let tuwunel_config =
		TuwunelConfig::new("tuwunel-server", "data");
	let config_toml = tuwunel_config
		.to_toml()
		.expect("failed to serialize tuwunel config");
	let config_path = tmp.path().join("tuwunel.toml");
	std::fs::write(&config_path, &config_toml)
		.expect("failed to write tuwunel config");

	// Staggered starts: alice at 5s after server, bob at 15s
	// after alice creates the room.
	let data_dir = tmp.path().join("shadow.data");
	let shadow_config = three_host_config(
		&tuwunel_bin,
		&client_bin,
		&config_path,
		&data_dir,
		"cs-api",
		"90s",
		42,
		"5s",
		"15s",
	);

	let shadow_yaml = shadow_config
		.to_yaml()
		.expect("failed to serialize shadow config");
	let shadow_yaml_path = tmp.path().join("shadow.yaml");
	std::fs::write(&shadow_yaml_path, &shadow_yaml)
		.expect("failed to write shadow config");

	// Run Shadow simulation
	let result = run_shadow(
		&shadow_yaml_path,
		42,
		Some(&data_dir),
		None,
	);

	assert!(
		result.success(),
		"Shadow CS API test failed with exit code {}.\n\
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

	let alice_stderrs =
		result.find_host_stderrs("alice-host");
	assert!(
		!alice_stderrs.is_empty(),
		"No stderr files found for alice-host"
	);
	let alice_stderr =
		std::fs::read_to_string(&alice_stderrs[0])
			.expect("failed to read alice stderr");
	assert!(
		alice_stderr
			.contains("alice: cs-api scenario complete"),
		"Alice did not complete cs-api scenario. Alice \
		 stderr:\n{alice_stderr}",
	);

	let bob_stderrs =
		result.find_host_stderrs("bob-host");
	assert!(
		!bob_stderrs.is_empty(),
		"No stderr files found for bob-host"
	);
	let bob_stderr =
		std::fs::read_to_string(&bob_stderrs[0])
			.expect("failed to read bob stderr");
	assert!(
		bob_stderr
			.contains("bob: cs-api scenario complete"),
		"Bob did not complete cs-api scenario. Bob \
		 stderr:\n{bob_stderr}",
	);

	// Bob must have received Alice's message
	assert!(
		bob_stderr.contains("Hello from Alice"),
		"Bob did not receive Alice's message. Bob \
		 stderr:\n{bob_stderr}",
	);

	eprintln!(
		"Shadow CS API test PASSED (seed={})",
		result.seed
	);
}
