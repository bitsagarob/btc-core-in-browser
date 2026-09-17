#!/bin/bash
# Stage a built bitcoin-qt into a web root with content-hashed filenames.
#
#   ./deploy.sh <build-bin-dir> <web-dir>
#
# The three big files get an 8 character content hash in the name, so they can
# be cached forever and a new build never serves a stale mix. Nothing fetches
# them by their original name: boot.js reads manifest.json and hands the bytes
# to Emscripten through instantiateWasm and getPreloadedPackage, so the names
# baked into the glue code are never used.
set -euo pipefail

BIN="${1:?usage: deploy.sh <build-bin-dir> <web-dir>}"
WEB="${2:?usage: deploy.sh <build-bin-dir> <web-dir>}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

[ -f "$BIN/bitcoin-qt.wasm" ] || { echo "no bitcoin-qt.wasm in $BIN"; exit 1; }
mkdir -p "$WEB"

# Static page files are copied as-is and cached briefly.
cp "$ROOT/web-gui/index.html" "$ROOT/web-gui/boot.js" "$ROOT/web-gui/boot.css" "$WEB/"

hash_of() { sha256sum "$1" | cut -c1-8; }

declare -A OUT
for kind in js wasm data; do
  src="$BIN/bitcoin-qt.$kind"
  [ -f "$src" ] || { echo "missing $src"; exit 1; }
  h="$(hash_of "$src")"
  name="bitcoin-qt.$h.$kind"
  cp "$src" "$WEB/$name"
  OUT[$kind]="$name"
  OUT[${kind}_size]="$(stat -c%s "$src")"
done

cat > "$WEB/manifest.json" <<EOF
{
  "js": "${OUT[js]}",
  "wasm": "${OUT[wasm]}",
  "data": "${OUT[data]}",
  "wasmSize": ${OUT[wasm_size]},
  "dataSize": ${OUT[data_size]}
}
EOF

# gzip_static serves these directly, which matters for a 55 MB wasm.
for f in "$WEB"/*.js "$WEB"/*.wasm "$WEB"/*.data "$WEB"/index.html "$WEB"/boot.css "$WEB"/manifest.json; do
  [ -f "$f" ] || continue
  gzip -9 -k -f "$f"
done
# A gzipped manifest is larger than the original, and gzip_static would still
# prefer it.
rm -f "$WEB/manifest.json.gz"

# Drop hashed files from older builds, otherwise the web root grows by 75 MB
# every time.
for f in "$WEB"/bitcoin-qt.*; do
  base="$(basename "$f")"
  stem="${base%.gz}"
  case "$stem" in
    "${OUT[js]}"|"${OUT[wasm]}"|"${OUT[data]}") ;;
    *) echo "removing stale $base"; rm -f "$f" ;;
  esac
done

echo "deployed to $WEB:"
ls -la "$WEB" | awk '{print $5, $9}'
