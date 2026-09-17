#!/bin/bash
# Stage a built bitcoin-qt into a web root with content-hashed filenames.
#
#   ./deploy.sh <build-bin-dir> <web-dir>
#
# The hash is a cache key, not a checksum: it guarantees a browser never mixes
# a new .js with an old .wasm. Integrity lives in build-info.json.
set -euo pipefail

BIN="${1:?usage: deploy.sh <build-bin-dir> <web-dir>}"
WEB="${2:?usage: deploy.sh <build-bin-dir> <web-dir>}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

case "$ROOT$BIN$WEB" in
  *" "*) echo "paths containing spaces are not supported"; exit 1 ;;
esac

# Everything is checked before anything is written, so a half-built directory
# cannot leave the served page pointing at files that were never copied.
for kind in js wasm data; do
  [ -f "$BIN/bitcoin-qt.$kind" ] || { echo "missing $BIN/bitcoin-qt.$kind"; exit 1; }
done
for f in index.html boot.js boot.css; do
  [ -f "$ROOT/web-gui/$f" ] || { echo "missing web-gui/$f"; exit 1; }
done
mkdir -p "$WEB"

declare -A OUT
for kind in js wasm data; do
  src="$BIN/bitcoin-qt.$kind"
  sum="$(sha256sum "$src" | cut -d' ' -f1)"
  name="bitcoin-qt.${sum:0:8}.$kind"
  # Copy to a dot-file and rename, so nginx never serves a half-written 55 MB
  # file under a name that promises fixed content.
  cp "$src" "$WEB/.$name.tmp"
  mv "$WEB/.$name.tmp" "$WEB/$name"
  OUT[$kind]="$name"
  OUT[${kind}_size]="$(stat -c%s "$src")"
  OUT[${kind}_sha]="$sum"
done

cp "$ROOT/web-gui/index.html" "$ROOT/web-gui/boot.js" "$ROOT/web-gui/boot.css" "$WEB/"

cat > "$WEB/manifest.json" <<EOF
{
  "js": "${OUT[js]}",
  "wasm": "${OUT[wasm]}",
  "data": "${OUT[data]}",
  "wasmSize": ${OUT[wasm_size]},
  "dataSize": ${OUT[data_size]}
}
EOF

# What a third party needs to check that the served bytes match this repository.
CORE_COMMIT="$(git -C "$ROOT/build/core" rev-parse HEAD 2>/dev/null || echo unknown)"
{
  echo '{'
  echo "  \"built\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"source\": \"$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)\","
  echo "  \"bitcoinCore\": { \"tag\": \"${CORE_TAG:-v31.1}\", \"commit\": \"$CORE_COMMIT\" },"
  echo '  "patches": {'
  first=1
  for p in "$ROOT"/patches/*.patch; do
    [ $first -eq 1 ] || echo ','
    first=0
    printf '    "%s": "%s"' "$(basename "$p")" "$(sha256sum "$p" | cut -d' ' -f1)"
  done
  echo
  echo '  },'
  echo "  \"artifacts\": {"
  echo "    \"${OUT[js]}\": \"${OUT[js_sha]}\","
  echo "    \"${OUT[wasm]}\": \"${OUT[wasm_sha]}\","
  echo "    \"${OUT[data]}\": \"${OUT[data_sha]}\""
  echo '  }'
  echo '}'
} > "$WEB/build-info.json"

# Older builds go before the new ones are compressed, otherwise every deploy
# spends a minute gzipping a 55 MB file it is about to delete.
for f in "$WEB"/bitcoin-qt.*; do
  base="$(basename "$f")"
  stem="${base%.gz}"
  case "$stem" in
    "${OUT[js]}"|"${OUT[wasm]}"|"${OUT[data]}") ;;
    *) echo "removing stale $base"; rm -f "$f" ;;
  esac
done

# gzip_static serves these directly, which matters for a 55 MB wasm. -n keeps
# the source mtime out of the archive, so an identical rebuild gzips identically.
for f in "$WEB"/*.js "$WEB"/*.wasm "$WEB"/*.data "$WEB"/index.html "$WEB"/boot.css; do
  [ -f "$f" ] || continue
  gzip -9 -n -k -f "$f"
done

echo "deployed to $WEB"
ls -la "$WEB" | awk '{print $5, $9}'
