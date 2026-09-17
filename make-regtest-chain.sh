#!/bin/bash
# Mine the regtest chain that gets baked into the browser build.
#
#   ./make-regtest-chain.sh [out-dir]
#
# Produces a datadir holding a few hundred blocks, a wallet with a spendable
# balance and real transaction history, and rewrites the tip timestamp inside
# web-gui/demo-clock.js so the built page agrees with the chain it ships.
#
# Needs a native bitcoind and bitcoin-cli on PATH.
set -euo pipefail

OUT="${1:-$(cd "$(dirname "$0")" && pwd)/build/preload}"
BLOCKS="${BLOCKS:-300}"
ROUNDS="${ROUNDS:-30}"      # blocks that also carry transactions
PER_ROUND="${PER_ROUND:-50}"
PORT="${PORT:-19998}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

for tool in bitcoind bitcoin-cli; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH"; exit 1; }
done

# The wasm build opens this datadir. A newer native bitcoind can write a
# chainstate or a descriptor wallet that an older Core will not read, and the
# failure then surfaces inside a browser with no log to read.
WANT="${CORE_TAG:-v31.1}"
bitcoind -version | head -1 | grep -q "${WANT%.*}" || {
  echo "native bitcoind is $(bitcoind -version | head -1), expected $WANT"
  exit 1
}

# $OUT is about to be removed recursively.
case "$OUT" in
  ""|"/"|"$HOME") echo "refusing to write to '$OUT'"; exit 1 ;;
esac
if [ -e "$OUT" ] && [ ! -f "$OUT/.made-by-make-regtest-chain" ]; then
  echo "$OUT exists and was not made by this script, refusing to delete it"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'bitcoin-cli -regtest -datadir="$TMP" -rpcport=$PORT stop >/dev/null 2>&1 || true; sleep 2; rm -rf "$TMP"' EXIT

cli() { bitcoin-cli -regtest -datadir="$TMP" -rpcport="$PORT" "$@"; }

bitcoind -regtest -datadir="$TMP" -listen=0 -rpcport="$PORT" -daemon -fallbackfee=0.0001 >/dev/null
cli -rpcwait getblockcount >/dev/null
cli createwallet bench >/dev/null
ADDR="$(cli getnewaddress)"

echo "==> mining $BLOCKS blocks"
cli generatetoaddress "$BLOCKS" "$ADDR" >/dev/null

echo "==> $((ROUNDS * PER_ROUND)) transactions across $ROUNDS blocks"
for _ in $(seq 1 "$ROUNDS"); do
  for _ in $(seq 1 "$PER_ROUND"); do cli sendtoaddress "$ADDR" 0.01 >/dev/null; done
  cli generatetoaddress 1 "$ADDR" >/dev/null
done

HEIGHT="$(cli getblockcount)"
TIPHASH="$(cli getbestblockhash)"
TIPTIME="$(cli getblockheader "$TIPHASH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["time"])')"
TXCOUNT="$(cli getchaintxstats | python3 -c 'import json,sys; print(json.load(sys.stdin)["txcount"])')"
# stop is asynchronous, and copying a LevelDB mid-flush bakes a corrupt
# chainstate into the preload that every visitor then downloads.
PID="$(cat "$TMP/regtest/bitcoind.pid" 2>/dev/null || true)"
cli stop >/dev/null
if [ -n "$PID" ]; then
  while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
else
  sleep 5
fi

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -r "$TMP/regtest" "$OUT"
# Runtime leftovers: the lock stops a second process, the log is noise, and the
# mempool would be replayed as unconfirmed transactions on first start.
# Everything below varies per run and means nothing to a node with no network.
rm -f "$OUT/.lock" "$OUT/debug.log" "$OUT/mempool.dat" "$OUT"/*.pid \
      "$OUT/peers.dat" "$OUT/anchors.dat" "$OUT/fee_estimates.dat" \
      "$OUT/blocks/.lock" "$OUT/blocks/index/LOCK" "$OUT/chainstate/LOCK"
touch "$OUT/.made-by-make-regtest-chain"

ISO="$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$TIPTIME")"
# A sed that quietly matches nothing would leave the page telling Core the
# wrong time, which shows up as the out-of-sync modal this shim exists to avoid.
grep -q "var TIP_MS = Date.parse('" "$ROOT/web-gui/demo-clock.js" || {
  echo "TIP_MS line not found in web-gui/demo-clock.js"; exit 1; }
sed -i "s|var TIP_MS = Date.parse('[^']*');|var TIP_MS = Date.parse('$ISO');|" "$ROOT/web-gui/demo-clock.js"
grep -q "Date.parse('$ISO')" "$ROOT/web-gui/demo-clock.js" || {
  echo "failed to write the new tip into web-gui/demo-clock.js"; exit 1; }

echo
echo "height   $HEIGHT"
echo "txcount  $TXCOUNT"
echo "tip      $ISO"
echo "datadir  $OUT  ($(du -sh "$OUT" | cut -f1))"
# The chain is a build input, so it is repacked here rather than left lying in
# a build directory. Deterministic flags: a tarball that differs only by mtime
# would defeat the point of pinning it.
FIXTURE="$ROOT/fixtures/regtest-chain.tar.gz"
mkdir -p "$ROOT/fixtures"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf - -C "$(dirname "$OUT")" "$(basename "$OUT")" | gzip -9 -n > "$FIXTURE"
SHA="$(sha256sum "$FIXTURE" | cut -d" " -f1)"
sed -i "s|^CHAIN_SHA=\".*\"|CHAIN_SHA=\"$SHA\"|" "$ROOT/build-gui.sh"

echo "fixture $FIXTURE"
echo "sha256   $SHA"
echo "demo-clock.js and build-gui.sh updated to the new chain"
