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
  shadow-multi
             Run the ignored Shadow multi-homeserver scenario explicitly.
  hosted     Run the E2E suite against the permanently hosted homeservers.
             Requires MANYMATRIX_HOSTED_SYNAPSE_URL,
             MANYMATRIX_HOSTED_SYNAPSE_REGISTRATION_SECRET,
             MANYMATRIX_HOSTED_TUWUNEL_URL and
             MANYMATRIX_HOSTED_TUWUNEL_REGISTRATION_TOKEN in the environment.
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

run_shadow_multi() {
  cargo test -p test-harness --test shadow --no-default-features --features shadow-tests -- multi_homeserver_message_delivery_over_shadow --ignored --nocapture
}

run_hosted() {
  local var
  for var in \
    MANYMATRIX_HOSTED_SYNAPSE_URL \
    MANYMATRIX_HOSTED_SYNAPSE_REGISTRATION_SECRET \
    MANYMATRIX_HOSTED_TUWUNEL_URL \
    MANYMATRIX_HOSTED_TUWUNEL_REGISTRATION_TOKEN; do
    if [[ -z "${!var:-}" ]]; then
      echo "error: $var must be set for the hosted tier" >&2
      exit 64
    fi
  done
  cargo test -p test-harness --no-default-features --features hosted-tests -- hosted
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
  shadow-multi)
    run_shadow_multi
    ;;
  hosted)
    run_hosted
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
