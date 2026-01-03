//! Resilience integration tests: restart persistence, federation
//! partition tolerance, and post-partition re-sync.

mod common;

use std::{path::Path, process::Command};

use shadow_test_harness::{
	config::{
		shadow::{
			partition_resync_config, restart_config,
			TopologyFixture,
		},
		tuwunel::TuwunelConfig,
	},
	runner::run_shadow,
};

#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test resilience -- --ignored
fn shadow_restart_persistence() {
	let (tuwunel_bin, client_bin) =
		common::build_shadow_binaries();

	let tmp = tempfile::tempdir()
		.expect("failed to create tempdir");

	let config = TuwunelConfig::new("tuwunel-server", "data");
	let config_path = tmp.path().join("tuwunel.toml");
	std::fs::write(
		&config_path,
		config
			.to_toml()
			.expect("failed to serialize config"),
	)
	.expect("failed to write config");

	let data_dir = tmp.path().join("shadow.data");
	let shadow_config = restart_config(
		&tuwunel_bin,
		&client_bin,
		&config_path,
		&data_dir,
		"60s", // server1 exits at 30s, restarts at 40s, verifier at 45s
		42,
	);

	let shadow_yaml = shadow_config
		.to_yaml()
		.expect("failed to serialize shadow config");
	let shadow_config_path = tmp.path().join("shadow.yaml");
	std::fs::write(&shadow_config_path, &shadow_yaml)
		.expect("failed to write shadow config");

	let result = run_shadow(
		&shadow_config_path,
		42,
		Some(&data_dir),
		None,
	);

	assert!(
		result.success(),
		"Shadow restart persistence test failed with exit \
		 code {}.\n\
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

	let writer_stderrs =
		result.find_host_stderrs("writer-client");
	assert!(
		!writer_stderrs.is_empty(),
		"No stderr files found for writer-client"
	);
	let writer_stderr =
		std::fs::read_to_string(&writer_stderrs[0])
			.expect("failed to read writer stderr");
	assert!(
		writer_stderr
			.contains("writer: resilience write complete"),
		"Writer did not complete. Writer stderr:\n\
		 {writer_stderr}",
	);

	let verifier_stderrs =
		result.find_host_stderrs("verifier-client");
	assert!(
		!verifier_stderrs.is_empty(),
		"No stderr files found for verifier-client"
	);
	let verifier_stderr =
		std::fs::read_to_string(&verifier_stderrs[0])
			.expect("failed to read verifier stderr");
	assert!(
		verifier_stderr.contains(
			"verifier: data persisted after restart"
		),
		"Verifier did not confirm persistence. Verifier \
		 stderr:\n{verifier_stderr}",
	);

	assert!(
		verifier_stderr
			.contains("pre-restart persistence test"),
		"Verifier did not find persisted message. Verifier \
		 stderr:\n{verifier_stderr}",
	);

	eprintln!(
		"Shadow restart persistence test PASSED (seed={})",
		result.seed
	);
}

/// Generate a self-signed TLS certificate and key via openssl CLI.
fn generate_self_signed_cert(
	dir: &Path,
	hostname: &str,
) -> (String, String) {
	let cert_path = dir.join(format!("{hostname}.crt"));
	let key_path = dir.join(format!("{hostname}.key"));

	let status = Command::new("openssl")
		.args([
			"req",
			"-x509",
			"-newkey",
			"rsa:2048",
			"-keyout",
			key_path.to_str().expect("key path UTF-8"),
			"-out",
			cert_path.to_str().expect("cert path UTF-8"),
			"-days",
			"1",
			"-nodes",
			"-subj",
			&format!("/CN={hostname}"),
		])
		.status()
		.expect("failed to run openssl");
	assert!(
		status.success(),
		"openssl cert generation failed for {hostname}"
	);

	(
		cert_path
			.to_str()
			.expect("cert path UTF-8")
			.to_owned(),
		key_path
			.to_str()
			.expect("key path UTF-8")
			.to_owned(),
	)
}

#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test resilience -- --ignored
fn shadow_partition() {
	let (tuwunel_bin, client_bin) =
		common::build_shadow_binaries();

	let tmp = tempfile::tempdir()
		.expect("failed to create tempdir");

	let (cert1, key1) =
		generate_self_signed_cert(tmp.path(), "server1");
	let (cert2, key2) =
		generate_self_signed_cert(tmp.path(), "server2");

	let config1 = TuwunelConfig::new("server1", "data")
		.with_federation("server2:8448", true)
		.with_tls(&cert1, &key1);
	let config1_path = tmp.path().join("server1.toml");
	std::fs::write(
		&config1_path,
		config1
			.to_toml()
			.expect("failed to serialize server1 config"),
	)
	.expect("failed to write server1 config");

	let config2 = TuwunelConfig::new("server2", "data")
		.with_federation("server1:8448", true)
		.with_tls(&cert2, &key2);
	let config2_path = tmp.path().join("server2.toml");
	std::fs::write(
		&config2_path,
		config2
			.to_toml()
			.expect("failed to serialize server2 config"),
	)
	.expect("failed to write server2 config");

	let data_dir = tmp.path().join("shadow.data");
	let topology = TopologyFixture::federation(10, 0.0);
	let shadow_config = partition_resync_config(
		&tuwunel_bin,
		&client_bin,
		&config1_path,
		&config2_path,
		&data_dir,
		&topology,
		"partition",
		"120s",
		42,
	);

	let shadow_yaml = shadow_config
		.to_yaml()
		.expect("failed to serialize shadow config");
	let shadow_config_path = tmp.path().join("shadow.yaml");
	std::fs::write(&shadow_config_path, &shadow_yaml)
		.expect("failed to write shadow config");

	let result = run_shadow(
		&shadow_config_path,
		42,
		Some(&data_dir),
		None,
	);

	assert!(
		result.success(),
		"Shadow partition test failed with exit code {}.\n\
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

	let setup_stderrs =
		result.find_host_stderrs("setup-client");
	assert!(
		!setup_stderrs.is_empty(),
		"No stderr files found for setup-client"
	);
	let setup_stderr =
		std::fs::read_to_string(&setup_stderrs[0])
			.expect("failed to read setup-client stderr");
	assert!(
		setup_stderr.contains(
			"creator: partition setup complete"
		),
		"Creator did not complete partition setup. Setup \
		 stderr:\n{setup_stderr}",
	);

	let survivor_stderrs =
		result.find_host_stderrs("survivor-client");
	assert!(
		!survivor_stderrs.is_empty(),
		"No stderr files found for survivor-client"
	);
	let survivor_stderr =
		std::fs::read_to_string(&survivor_stderrs[0])
			.expect("failed to read survivor stderr");
	assert!(
		survivor_stderr.contains(
			"survivor: sent message during partition"
		),
		"Survivor did not send message. Survivor stderr:\n\
		 {survivor_stderr}",
	);

	let verifier_stderrs =
		result.find_host_stderrs("verifier-client");
	assert!(
		!verifier_stderrs.is_empty(),
		"No stderr files found for verifier-client"
	);
	let verifier_stderr =
		std::fs::read_to_string(&verifier_stderrs[0])
			.expect("failed to read verifier stderr");
	assert!(
		verifier_stderr.contains(
			"verifier: partition recovery verified"
		),
		"Verifier did not confirm partition recovery. \
		 Verifier stderr:\n{verifier_stderr}",
	);

	eprintln!(
		"Shadow partition test PASSED (seed={})",
		result.seed
	);
}

#[test]
#[ignore] // Run explicitly: cargo test -p shadow-test-harness --test resilience -- --ignored
fn shadow_resync() {
	let (tuwunel_bin, client_bin) =
		common::build_shadow_binaries();

	let tmp = tempfile::tempdir()
		.expect("failed to create tempdir");

	let (cert1, key1) =
		generate_self_signed_cert(tmp.path(), "server1");
	let (cert2, key2) =
		generate_self_signed_cert(tmp.path(), "server2");

	let config1 = TuwunelConfig::new("server1", "data")
		.with_federation("server2:8448", true)
		.with_tls(&cert1, &key1);
	let config1_path = tmp.path().join("server1.toml");
	std::fs::write(
		&config1_path,
		config1
			.to_toml()
			.expect("failed to serialize server1 config"),
	)
	.expect("failed to write server1 config");

	let config2 = TuwunelConfig::new("server2", "data")
		.with_federation("server1:8448", true)
		.with_tls(&cert2, &key2);
	let config2_path = tmp.path().join("server2.toml");
	std::fs::write(
		&config2_path,
		config2
			.to_toml()
			.expect("failed to serialize server2 config"),
	)
	.expect("failed to write server2 config");

	let data_dir = tmp.path().join("shadow.data");
	let topology = TopologyFixture::federation(10, 0.0);
	let shadow_config = partition_resync_config(
		&tuwunel_bin,
		&client_bin,
		&config1_path,
		&config2_path,
		&data_dir,
		&topology,
		"resync",
		"120s",
		42,
	);

	let shadow_yaml = shadow_config
		.to_yaml()
		.expect("failed to serialize shadow config");
	let shadow_config_path = tmp.path().join("shadow.yaml");
	std::fs::write(&shadow_config_path, &shadow_yaml)
		.expect("failed to write shadow config");

	let result = run_shadow(
		&shadow_config_path,
		42,
		Some(&data_dir),
		None,
	);

	assert!(
		result.success(),
		"Shadow resync test failed with exit code {}.\n\
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

	let setup_stderrs =
		result.find_host_stderrs("setup-client");
	assert!(
		!setup_stderrs.is_empty(),
		"No stderr files found for setup-client"
	);
	let setup_stderr =
		std::fs::read_to_string(&setup_stderrs[0])
			.expect("failed to read setup-client stderr");
	assert!(
		setup_stderr
			.contains("creator: resync setup complete"),
		"Creator did not complete resync setup. Setup \
		 stderr:\n{setup_stderr}",
	);

	let survivor_stderrs =
		result.find_host_stderrs("survivor-client");
	assert!(
		!survivor_stderrs.is_empty(),
		"No stderr files found for survivor-client"
	);
	let survivor_stderr =
		std::fs::read_to_string(&survivor_stderrs[0])
			.expect("failed to read survivor stderr");
	assert!(
		survivor_stderr.contains(
			"survivor: sent missed message during \
			 server2 downtime"
		),
		"Survivor did not send missed message. Survivor \
		 stderr:\n{survivor_stderr}",
	);

	let verifier_stderrs =
		result.find_host_stderrs("verifier-client");
	assert!(
		!verifier_stderrs.is_empty(),
		"No stderr files found for verifier-client"
	);
	let verifier_stderr =
		std::fs::read_to_string(&verifier_stderrs[0])
			.expect("failed to read verifier stderr");
	assert!(
		verifier_stderr.contains(
			"verifier: re-sync verified, missed message \
			 received"
		),
		"Verifier did not confirm re-sync. Verifier \
		 stderr:\n{verifier_stderr}",
	);

	assert!(
		verifier_stderr
			.contains("missed during downtime"),
		"Verifier did not find missed message text. \
		 Verifier stderr:\n{verifier_stderr}",
	);

	eprintln!(
		"Shadow resync test PASSED (seed={})",
		result.seed
	);
}
