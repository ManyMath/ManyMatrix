//! Shared test helpers for Shadow integration tests.

use std::{path::PathBuf, process::Command};

/// Build tuwunel and matrix-test-client with the shadow profile.
///
/// This is slow (release-level build) but ensures binaries are
/// available for Shadow simulation. Returns paths to both binaries.
pub fn build_shadow_binaries() -> (PathBuf, PathBuf) {
	let workspace_root =
		PathBuf::from(env!("CARGO_MANIFEST_DIR"))
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
			"failed to run cargo build for \
			 matrix-test-client",
		);
	assert!(
		status.success(),
		"Failed to build matrix-test-client with shadow \
		 profile"
	);

	let tuwunel_bin =
		workspace_root.join("target/shadow/tuwunel");
	let client_bin = workspace_root
		.join("target/shadow/matrix-test-client");

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
