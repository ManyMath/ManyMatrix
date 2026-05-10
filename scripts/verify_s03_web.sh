#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "[verify-s03] FAIL at $1" >&2; exit 1; }

for var in \
  MANYMATRIX_HOSTED_SYNAPSE_URL \
  MANYMATRIX_HOSTED_SYNAPSE_REGISTRATION_SECRET \
  MANYMATRIX_HOSTED_TUWUNEL_URL \
  MANYMATRIX_HOSTED_TUWUNEL_REGISTRATION_TOKEN; do
  [[ -n "${!var:-}" ]] || fail "$var must be set (see ~/dev/hetzner README section 8)"
done

echo "[verify-s03] 1/5 wasm-pack build crates/web"
wasm-pack build --target web --release crates/web || fail "wasm-pack build"

echo "[verify-s03] 2/5 build extension"
(cd flutter_plugin/example && dart run tool/build_extension.dart) || fail "build_extension.dart"
[[ -d flutter_plugin/example/build/extension ]] || fail "extension dir missing"

echo "[verify-s03] 3/5 build web_e2e_actor"
cargo build -p test-harness --bin web_e2e_actor --no-default-features --features hosted-tests \
  || fail "web_e2e_actor build"

echo "[verify-s03] 4/5 npm install (testing/web-e2e)"
(cd testing/web-e2e && npm install --no-audit --no-fund) || fail "npm install"

echo "[verify-s03] 5/5 web E2E against both hosted servers"
node testing/web-e2e/run.mjs hosted-synapse || fail "hosted-synapse"
node testing/web-e2e/run.mjs hosted-tuwunel || fail "hosted-tuwunel"

echo "[verify-s03] OK"
