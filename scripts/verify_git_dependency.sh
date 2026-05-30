#!/usr/bin/env bash
# Verifies that manymatrix-core can be consumed as a `git` Cargo dependency
# without the workspace-local ruma-client-api vendor patch (PUB-01). See
# ROADMAP.md's "Package Publishing & Release Automation" section: an actual
# `cargo publish` to crates.io is blocked upstream, but downstream consumers
# can already depend on this repo directly via `git`.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "[verify-git-dep] FAIL at $1" >&2; exit 1; }

REPO_ROOT="$(pwd)"
REV="$(git rev-parse HEAD)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "[verify-git-dep] 1/2 scaffold a consumer crate depending on manymatrix-core via git"
(
  cd "$SCRATCH"
  cargo init --name consumer_test -q
  cat > Cargo.toml <<EOF
[package]
name = "consumer_test"
version = "0.1.0"
edition = "2021"

[dependencies]
manymatrix-core = { git = "file://${REPO_ROOT}", rev = "${REV}" }
EOF
) || fail "scaffold consumer crate"

echo "[verify-git-dep] 2/2 cargo check the consumer crate (must succeed without the vendor patch)"
(cd "$SCRATCH" && cargo check) || fail "consumer crate cargo check"

echo "[verify-git-dep] OK"
