#!/usr/bin/env bash
# Assemble a minimal extension for the web E2E harness: the extension
# sources plus the wasm-pack output, no Flutter app build. The harness's
# injected e2e.html driver page never loads the Flutter UI, so this is
# equivalent for CI (and much cheaper than a full flutter build web).
set -euo pipefail

out="${1:?usage: assemble_web_e2e_extension.sh <outdir>}"
# Resolve a relative output directory against the caller's directory before
# moving to the repository root.
case "$out" in
  /*) ;;
  *) out="$PWD/$out" ;;
esac
cd "$(dirname "$0")/.."

[[ -f crates/web/pkg/manymatrix_web_bg.wasm ]] || {
  echo "error: crates/web/pkg missing, run: wasm-pack build --target web --release crates/web" >&2
  exit 1
}

mkdir -p "$out/pkg"
cp flutter_plugin/example/extension/* "$out/"
cp apps/ManyMatrix/web/manymatrix_worker.js \
  apps/ManyMatrix/web/manymatrix_worker_protocol.mjs "$out/"
cp crates/web/pkg/manymatrix_web.js crates/web/pkg/manymatrix_web_bg.wasm "$out/pkg/"
# Chrome refuses to load the extension when side_panel.default_path points
# at a missing file, so stub out the Flutter app entry point.
printf '<!DOCTYPE html><title>manymatrix e2e stub</title>\n' > "$out/index.html"

echo "minimal web-e2e extension assembled at $out"
