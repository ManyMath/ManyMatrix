#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site_app_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$site_app_dir/../.." && pwd)"
matrix_app_dir="$repo_root/apps/ManyMatrix"
manyui_dir="$repo_root/../ManyUI/manyui"

for command in flutter wasm-pack; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to build ManyMatrix.com" >&2
    exit 1
  }
done
test -s "$manyui_dir/pubspec.yaml" || {
  echo "missing sibling ManyUI package: $manyui_dir" >&2
  echo "check out ManyUI beside ManyMatrix before building the web distribution" >&2
  exit 1
}

wasm-pack build \
  --target web \
  --release \
  --out-dir "$matrix_app_dir/web/pkg" \
  "$repo_root/crates/web"

rm -rf "$matrix_app_dir/build/web"
(
  cd "$matrix_app_dir"
  flutter build web \
    --release \
    --base-href=/chat/ \
    --pwa-strategy=none \
    --no-web-resources-cdn \
    --no-wasm-dry-run
)

"$script_dir/assemble_web_dist.sh"
