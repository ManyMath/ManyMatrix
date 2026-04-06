#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "[verify-s02] FAIL at $1" >&2; exit 1; }

echo "[verify-s02] 1/7 cargo check -p manymatrix-core --target wasm32-unknown-unknown"
cargo check -p manymatrix-core --target wasm32-unknown-unknown || fail "cargo check manymatrix-core wasm32"

echo "[verify-s02] 2/7 wasm-pack build crates/web"
wasm-pack build --target web --release crates/web || fail "wasm-pack build"
[[ -f crates/web/pkg/manymatrix_web_bg.wasm ]] || fail "wasm artifact missing"

echo "[verify-s02] 3/7 flutter analyze"
(cd flutter_plugin && flutter analyze) || fail "flutter analyze"

echo "[verify-s02] 4/7 cargo test --workspace --exclude manymatrix-web (native regression)"
cargo test --workspace --exclude manymatrix-web || fail "cargo test --workspace"

echo "[verify-s02] 5/7 S01 regression (verify_s01_web.sh)"
bash scripts/verify_s01_web.sh || fail "verify_s01_web.sh"

echo "[verify-s02] 6/7 build extension"
(cd flutter_plugin/example && dart run tool/build_extension.dart) || fail "build_extension.dart"
[[ -f flutter_plugin/example/build/extension.zip ]] || fail "extension.zip missing"

echo "[verify-s02] 7/7 extension.zip contents + wasm size check"
unzip -l flutter_plugin/example/build/extension.zip | grep -q 'pkg/manymatrix_web_bg.wasm' || fail "wasm missing from zip"
unzip -l flutter_plugin/example/build/extension.zip | grep -q 'sw.js' || fail "sw.js missing from zip"
unzip -l flutter_plugin/example/build/extension.zip | grep -q 'offscreen.html' || fail "offscreen.html missing from zip"
WASM_SIZE=$(wc -c < crates/web/pkg/manymatrix_web_bg.wasm)
echo "[verify-s02] wasm size: ${WASM_SIZE} bytes"
if (( WASM_SIZE < 100000 )); then
  fail "wasm too small (${WASM_SIZE} bytes), auth+sync code likely missing"
fi

echo "[verify-s02] OK"
