#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site_app_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$site_app_dir/../.." && pwd)"
site_dir="$site_app_dir/site"
flutter_dir="$repo_root/apps/ManyMatrix/build/web"
dist_dir="$site_app_dir/build/dist"
staging_dir="$site_app_dir/build/.dist-staging-$$"

cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

required_site_assets=(
  index.html
  styles.css
  assets/manymatrix-mark.svg
  assets/manymatrix-app.png
)
for relative_path in "${required_site_assets[@]}"; do
  test -s "$site_dir/$relative_path" || {
    echo "missing ManyMatrix.com site artifact: $site_dir/$relative_path" >&2
    exit 1
  }
done
if [[ -e "$site_dir/chat" ]]; then
  echo "the company site may not contain a chat path; /chat/ is reserved for Flutter" >&2
  exit 1
fi

required_flutter_assets=(
  index.html
  flutter_bootstrap.js
  main.dart.js
  manifest.json
  manymatrix_worker.js
  manymatrix_worker_protocol.mjs
  pkg/manymatrix_web.js
  pkg/manymatrix_web_bg.wasm
)
for relative_path in "${required_flutter_assets[@]}"; do
  test -s "$flutter_dir/$relative_path" || {
    echo "missing ManyMatrix Flutter artifact: $flutter_dir/$relative_path" >&2
    exit 1
  }
done

grep -Fq '<base href="/chat/">' "$flutter_dir/index.html" || {
  echo "Flutter output does not have the required /chat/ base href" >&2
  exit 1
}
if [[ -s "$flutter_dir/flutter_service_worker.js" ]]; then
  echo "Flutter output unexpectedly contains an active service worker" >&2
  exit 1
fi

wasm_magic="$(od -An -tx1 -N4 "$flutter_dir/pkg/manymatrix_web_bg.wasm" | tr -d '[:space:]')"
if [[ "$wasm_magic" != "0061736d" ]]; then
  echo "manymatrix_web_bg.wasm is not a valid WebAssembly binary" >&2
  exit 1
fi

rm -rf "$staging_dir"
mkdir -p "$staging_dir/chat"
cp -R "$site_dir/." "$staging_dir/"
cp -R "$flutter_dir/." "$staging_dir/chat/"

rm -rf "$dist_dir"
mv "$staging_dir" "$dist_dir"
trap - EXIT

echo "Assembled ManyMatrix.com distribution at $dist_dir"
