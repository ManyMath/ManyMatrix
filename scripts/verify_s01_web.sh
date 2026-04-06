#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "[verify-s01] FAIL at $1" >&2; exit 1; }

echo "[verify-s01] 1/6 cargo check --workspace --exclude manymatrix-web"
cargo check --workspace --exclude manymatrix-web || fail "cargo check --workspace"

echo "[verify-s01] 2/6 cargo check -p manymatrix-web --target wasm32-unknown-unknown"
cargo check -p manymatrix-web --target wasm32-unknown-unknown || fail "cargo check wasm32"

echo "[verify-s01] 3/6 wasm-pack build crates/web"
wasm-pack build --target web --release crates/web || fail "wasm-pack build"
[[ -f crates/web/pkg/manymatrix_web_bg.wasm ]] || fail "wasm artifact missing"

echo "[verify-s01] 4/6 cargo test --workspace --exclude manymatrix-web (native regression)"
cargo test --workspace --exclude manymatrix-web || fail "cargo test --workspace"

echo "[verify-s01] 5/6 scripts/compatibility.sh embedded"
bash scripts/compatibility.sh embedded || fail "compatibility.sh embedded"

echo "[verify-s01] 6/6 build extension"
(cd flutter_plugin/example && dart run tool/build_extension.dart) || fail "build_extension.dart"
[[ -f flutter_plugin/example/build/extension.zip ]] || fail "extension.zip missing"
unzip -l flutter_plugin/example/build/extension.zip | grep -q 'pkg/manymatrix_web_bg.wasm' || fail "wasm missing from zip"
unzip -l flutter_plugin/example/build/extension.zip | grep -q 'sw.js' || fail "sw.js missing from zip"
unzip -l flutter_plugin/example/build/extension.zip | grep -q 'offscreen.html' || fail "offscreen.html missing from zip"

echo "[verify-s01] OK"
