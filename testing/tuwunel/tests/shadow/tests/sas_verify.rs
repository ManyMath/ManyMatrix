use std::{path::PathBuf, process::Command};

use shadow_test_harness::{
	config::{
		shadow::three_host_config,
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
	assert!(
		status.success(),
		"Failed to build tuwunel with shadow profile"
	);

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
		.expect(
			"failed to run cargo build for matrix-test-client",
		);
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

#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test sas_verify -- --ignored
fn shadow_sas_verify() {
	let (tuwunel_bin, client_bin) = build_shadow_binaries();

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

	// 180s stop_time: SAS verification has ~8 round-trip messages
	// via to-device events, so needs generous simulated time.
	let data_dir = tmp.path().join("shadow.data");
	let shadow_config = three_host_config(
		&tuwunel_bin,
		&client_bin,
		&config_path,
		&data_dir,
		"sas-verify",
		"180s",
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

	let result = run_shadow(
		&shadow_yaml_path,
		42,
		Some(&data_dir),
		None,
	);

	assert!(
		result.success(),
		"Shadow SAS verify test failed with exit code {}.\n\
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

	let alice_stderrs = result.find_host_stderrs("alice-host");
	assert!(
		!alice_stderrs.is_empty(),
		"No stderr files found for alice-host"
	);
	let alice_stderr = std::fs::read_to_string(&alice_stderrs[0])
		.expect("failed to read alice stderr");

	let bob_stderrs = result.find_host_stderrs("bob-host");
	assert!(
		!bob_stderrs.is_empty(),
		"No stderr files found for bob-host"
	);
	let bob_stderr = std::fs::read_to_string(&bob_stderrs[0])
		.expect("failed to read bob stderr");

	assert!(
		alice_stderr
			.contains("alice: sas verification complete"),
		"Alice did not complete SAS verification.\nAlice \
		 stderr:\n{alice_stderr}"
	);

	assert!(
		bob_stderr.contains("bob: sas verification complete"),
		"Bob did not complete SAS verification.\nBob \
		 stderr:\n{bob_stderr}"
	);

	// Verify key protocol steps were observed
	assert!(
		alice_stderr
			.contains("sent verification request to bob"),
		"Alice did not send verification request.\nAlice \
		 stderr:\n{alice_stderr}"
	);

	assert!(
		bob_stderr
			.contains("received verification.request from alice"),
		"Bob did not receive verification request.\nBob \
		 stderr:\n{bob_stderr}"
	);

	assert!(
		alice_stderr
			.contains("received verification.ready from bob"),
		"Alice did not receive ready from bob.\nAlice \
		 stderr:\n{alice_stderr}"
	);

	assert!(
		alice_stderr.contains("device keys uploaded"),
		"Alice did not upload device keys.\nAlice \
		 stderr:\n{alice_stderr}"
	);

	assert!(
		bob_stderr.contains("device keys uploaded"),
		"Bob did not upload device keys.\nBob \
		 stderr:\n{bob_stderr}"
	);

	eprintln!(
		"Shadow SAS verification test PASSED (seed={})",
		result.seed,
	);
}
