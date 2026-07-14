#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site_app_dir="$(cd "$script_dir/.." && pwd)"
dist_dir="${1:-$site_app_dir/build/dist}"
server_log="${TMPDIR:-/tmp}/manymatrix-com-smoke-$$.log"
download_dir="${TMPDIR:-/tmp}/manymatrix-com-smoke-$$"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$download_dir" "$server_log"
}
trap cleanup EXIT

for command in curl python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to verify the ManyMatrix.com distribution" >&2
    exit 1
  }
done

port="${MANYMATRIX_COM_SMOKE_PORT:-$(python3 -c '
import socket

with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    print(server.getsockname()[1])
')}"

required_files=(
  index.html
  styles.css
  assets/manymatrix-mark.svg
  assets/manymatrix-app.png
  chat/index.html
  chat/flutter_bootstrap.js
  chat/main.dart.js
  chat/manymatrix_worker.js
  chat/manymatrix_worker_protocol.mjs
  chat/pkg/manymatrix_web.js
  chat/pkg/manymatrix_web_bg.wasm
)
for relative_path in "${required_files[@]}"; do
  test -s "$dist_dir/$relative_path" || {
    echo "missing distribution artifact: $dist_dir/$relative_path" >&2
    exit 1
  }
done

required_site_links=(
  'href="/chat/"'
  'href="https://manymath.com/"'
  'href="https://manykee.com/"'
  'href="https://manytype.com/"'
  'href="https://manytier.com/"'
)
for site_link in "${required_site_links[@]}"; do
  grep -Fq "$site_link" "$dist_dir/index.html" || {
    echo "missing required ecosystem link in distribution: $site_link" >&2
    exit 1
  }
done

grep -Fq '<base href="/chat/">' "$dist_dir/chat/index.html" || {
  echo "composed chat app does not have the required /chat/ base href" >&2
  exit 1
}
if [[ -s "$dist_dir/chat/flutter_service_worker.js" ]]; then
  echo "composed chat app unexpectedly contains an active service worker" >&2
  exit 1
fi

mkdir -p "$download_dir"
python3 -m http.server "$port" \
  --bind 127.0.0.1 \
  --directory "$dist_dir" >"$server_log" 2>&1 &
server_pid=$!

for _ in $(seq 1 50); do
  if curl --fail --silent --show-error "http://127.0.0.1:$port/" \
    --output "$download_dir/site.html" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if ! kill -0 "$server_pid" 2>/dev/null; then
  cat "$server_log" >&2
  echo "ManyMatrix.com distribution server failed to start" >&2
  exit 1
fi

curl --fail --silent --show-error "http://127.0.0.1:$port/chat/" \
  --output "$download_dir/chat.html"
curl --fail --silent --show-error "http://127.0.0.1:$port/styles.css" \
  --output "$download_dir/styles.css"
curl --fail --silent --show-error "http://127.0.0.1:$port/assets/manymatrix-mark.svg" \
  --output "$download_dir/manymatrix-mark.svg"
curl --fail --silent --show-error "http://127.0.0.1:$port/assets/manymatrix-app.png" \
  --output "$download_dir/manymatrix-app.png"
curl --fail --silent --show-error "http://127.0.0.1:$port/chat/main.dart.js" \
  --output "$download_dir/main.dart.js"
curl --fail --silent --show-error "http://127.0.0.1:$port/chat/manymatrix_worker.js" \
  --output "$download_dir/manymatrix_worker.js"
curl --fail --silent --show-error "http://127.0.0.1:$port/chat/pkg/manymatrix_web.js" \
  --output "$download_dir/manymatrix_web.js"
curl --fail --silent --show-error "http://127.0.0.1:$port/chat/pkg/manymatrix_web_bg.wasm" \
  --output "$download_dir/manymatrix_web_bg.wasm"

grep -Fq '<base href="/chat/">' "$download_dir/chat.html"
if grep -Eiq '<!doctype html|<html' "$download_dir/styles.css"; then
  echo "/styles.css returned HTML" >&2
  exit 1
fi
if ! grep -Fq '<svg' "$download_dir/manymatrix-mark.svg"; then
  echo "/assets/manymatrix-mark.svg is not an SVG image" >&2
  exit 1
fi
preview_magic="$(od -An -tx1 -N8 "$download_dir/manymatrix-app.png" | tr -d '[:space:]')"
if [[ "$preview_magic" != "89504e470d0a1a0a" ]]; then
  echo "served manymatrix-app.png is not a valid PNG image" >&2
  exit 1
fi
for javascript in main.dart.js manymatrix_worker.js manymatrix_web.js; do
  if grep -Eiq '<!doctype html|<html' "$download_dir/$javascript"; then
    echo "/chat/$javascript returned HTML" >&2
    exit 1
  fi
done
wasm_magic="$(od -An -tx1 -N4 "$download_dir/manymatrix_web_bg.wasm" | tr -d '[:space:]')"
if [[ "$wasm_magic" != "0061736d" ]]; then
  echo "served manymatrix_web_bg.wasm is not a valid WebAssembly binary" >&2
  exit 1
fi

for missing_path in chat/missing.js chat/pkg/missing.wasm; do
  status="$({ curl --silent --show-error \
    --output "$download_dir/missing" \
    --write-out '%{http_code}' \
    "http://127.0.0.1:$port/$missing_path"; } || true)"
  if [[ "$status" != "404" ]]; then
    echo "/$missing_path returned $status instead of 404" >&2
    exit 1
  fi
  if cmp -s "$download_dir/missing" "$download_dir/site.html" || \
    cmp -s "$download_dir/missing" "$download_dir/chat.html"; then
    echo "/$missing_path fell back to an application entry point" >&2
    exit 1
  fi
done

echo "Verified ManyMatrix.com at / and the ManyMatrix web app at /chat/."
