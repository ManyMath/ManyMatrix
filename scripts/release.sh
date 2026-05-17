#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Publishable Rust crates, in dependency order (core first).
PUBLISHABLE_CRATES=(manymatrix-core manymatrix-cli manymatrix-ffi)

# Cargo.toml files carrying a workspace-synced Rust crate version.
CARGO_TOMLS=(
  Cargo.toml
  crates/core/Cargo.toml
  crates/cli/Cargo.toml
  crates/ffi/Cargo.toml
  crates/web/Cargo.toml
)

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh <command> [args]

Commands:
  check              Run the roadmap verification gates, then `cargo publish
                      --dry-run` for each publishable crate (core, cli, ffi)
                      in dependency order. Does not touch the network beyond
                      the dry-run's registry index check.
  version <X.Y.Z>     Bump the Rust workspace version (root [workspace.package]
                      plus each crate's own `version` and any pinned
                      `path = "..." , version = "..."` dependency) to X.Y.Z
                      across all Cargo.toml files. Does NOT touch
                      flutter_plugin/pubspec.yaml, which carries its own
                      independent version+build number, bump that by hand.
  tag                 Create an annotated git tag `v<workspace version>` at
                      HEAD. Does not push; review with `git show` and push
                      yourself when ready.
  help                Show this help.

Known blocker (see CHANGELOG.md "Unreleased"): this workspace depends on a
`[patch.crates-io]` override for ruma-client-api (vendor/ruma-client-api-0.22.0)
to compile against matrix-sdk 0.16.0. Cargo patches are workspace-local and are
NOT applied when verifying a packaged tarball or when a downstream consumer
depends on the crate from crates.io, so `cargo publish` currently fails
verification (E0004 in ruma-client-api's NewPushRule match). Publishing to
crates.io is blocked until upstream ruma-client-api ships the fix or the
patch is dropped. `check` still runs the dry-run so this stays visible.
USAGE
}

cmd_check() {
  echo "==> cargo check --workspace --exclude manymatrix-web"
  cargo check --workspace --exclude manymatrix-web
  echo "==> cargo check -p manymatrix-web --target wasm32-unknown-unknown"
  cargo check -p manymatrix-web --target wasm32-unknown-unknown
  echo "==> cargo test --workspace --exclude manymatrix-web"
  cargo test --workspace --exclude manymatrix-web
  echo "==> flutter analyze (flutter_plugin)"
  (cd flutter_plugin && flutter analyze)

  local failed=0
  for crate in "${PUBLISHABLE_CRATES[@]}"; do
    echo "==> cargo publish --dry-run -p $crate"
    if ! cargo publish --dry-run -p "$crate" --allow-dirty; then
      echo "!!  $crate failed dry-run verification (see known blocker in 'scripts/release.sh help')"
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    echo
    echo "One or more crates failed 'cargo publish --dry-run'. This is expected"
    echo "while the ruma-client-api patch is required, see 'scripts/release.sh help'."
    return 1
  fi
  echo "All publishable crates passed dry-run verification."
}

cmd_version() {
  local new_version="${1:?usage: scripts/release.sh version X.Y.Z}"
  local current_version
  current_version=$(grep -m1 '^version = ' Cargo.toml | sed -E 's/version = "([^"]+)"/\1/')

  echo "==> bumping Rust workspace version: $current_version -> $new_version"
  for f in "${CARGO_TOMLS[@]}"; do
    sed -i -E "s/^version = \"${current_version}\"/version = \"${new_version}\"/" "$f"
    sed -i -E "s/(path = \"[^\"]+\", version = )\"${current_version}\"/\1\"${new_version}\"/" "$f"
  done

  echo "==> updating Cargo.lock"
  cargo update --workspace --offline 2>/dev/null || cargo check --workspace --exclude manymatrix-web >/dev/null

  echo
  echo "Rust crates now at $new_version. Remaining manual steps:"
  echo "  - Move CHANGELOG.md [Unreleased] entries under a new ## [$new_version] - $(date +%Y-%m-%d) heading"
  echo "  - Bump flutter_plugin/pubspec.yaml version (independent X.Y.Z+build scheme)"
  echo "  - Review the diff, commit, then run: scripts/release.sh tag"
}

cmd_tag() {
  local version
  version=$(grep -m1 '^version = ' Cargo.toml | sed -E 's/version = "([^"]+)"/\1/')
  local tag="v${version}"

  if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "Tag $tag already exists." >&2
    exit 1
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree has uncommitted changes; commit the version bump first." >&2
    exit 1
  fi

  git tag -a "$tag" -m "Release $tag"
  echo "Created annotated tag $tag at $(git rev-parse --short HEAD)."
  echo "Review with: git show $tag"
  echo "Push yourself when ready: git push <remote> $tag"
}

case "${1:-help}" in
  check) cmd_check ;;
  version) cmd_version "${2:-}" ;;
  tag) cmd_tag ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
