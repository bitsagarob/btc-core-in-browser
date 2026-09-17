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

command -v bitcoind >/dev/null || { echo "bitcoind not on PATH"; exit 1; }

TMP="$(mktemp -d)"
trap 'bitcoin-cli -regtest -datadir="$TMP" -rpcport=$PORT stop >/dev/null 2>&1 || true; sleep 2; rm -rf "$TMP"' EXIT

cli() { bitcoin-cli -regtest -datadir="$TMP" -rpcport="$PORT" "$@"; }

bitcoind -regtest -datadir="$TMP" -listen=0 -rpcport="$PORT" -daemon -fallbackfee=0.0001 >/dev/null
sleep 4
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
cli stop >/dev/null
sleep 3

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -r "$TMP/regtest" "$OUT"
# Runtime leftovers: the lock stops a second process, the log is noise, and the
# mempool would be replayed as unconfirmed transactions on first start.
rm -f "$OUT/.lock" "$OUT/debug.log" "$OUT/mempool.dat" "$OUT"/*.pid

ISO="$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$TIPTIME")"
sed -i "s|var TIP_MS = Date.parse('[^']*');|var TIP_MS = Date.parse('$ISO');|" "$ROOT/web-gui/demo-clock.js"

echo
echo "height   $HEIGHT"
echo "txcount  $TXCOUNT"
echo "tip      $ISO"
echo "datadir  $OUT  ($(du -sh "$OUT" | cut -f1))"
echo "demo-clock.js updated to the new tip"
