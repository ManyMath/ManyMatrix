#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat <<'USAGE'
Usage: scripts/compatibility.sh <command>

Commands:
  embedded   Run the default embedded Tuwunel compatibility tier.
  report     Generate the embedded compatibility report under target/compat/.
  docker     Run the Docker-inclusive compatibility report tier.
  shadow     Run optional Shadow compatibility scenarios.
  all-local  Run embedded and report tiers only; excludes Docker and Shadow.
  help       Show this help.
USAGE
}

run_embedded() {
  cargo test -p test-harness
}

run_report() {
  cargo test -p test-harness compatibility_report --no-default-features --features embedded-tests -- --nocapture
}

run_docker() {
  cargo test -p test-harness compatibility_report --features docker-tests -- --nocapture
}

run_shadow() {
  cargo test -p test-harness --test shadow --no-default-features --features shadow-tests -- --nocapture
}

command="${1:-help}"

case "$command" in
  embedded)
    run_embedded
    ;;
  report)
    run_report
    ;;
  docker)
    run_docker
    ;;
  shadow)
    run_shadow
    ;;
  all-local)
    run_embedded
    run_report
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
