# bitcoin-core-wasm

Bitcoin Core's real consensus and validation engine, compiled to WebAssembly and
running in a browser. Not a reimplementation and not a subset: this is
`libbitcoinkernel` from bitcoin/bitcoin at tag `v31.1`, cross compiled with
Emscripten, with one upstream patch.

## What works

Headless Chromium, cross-origin isolated, no native helper:

* 330 regtest blocks holding 1831 transactions validated to height 330, exit 0
* LevelDB block index and chainstate written through Emscripten's filesystem
* four script verification threads running as web workers
* the same binary reaches the same tip under Node

A native `bitcoind` v31.1.0 then opened the datadir the WebAssembly build had
written and reported the identical best block hash, so the on-disk format is the
same in both directions.

## Measured

| | |
|---|---|
| Chromium, 330 blocks / 1831 tx | 0.66 s |
| Node, same binary | 0.73 s |
| native x86-64, same input | 0.24 s |
| `bitcoin-chainstate.wasm` | 2.4 MB |

About 3x native on this workload. The run is short enough that process startup
is part of it, so treat the ratio as a ceiling, not a benchmark.

## What does not work yet

* **No persistence.** The demo uses MEMFS, which is gone on reload. LevelDB over
  OPFS is the next piece of work and is untested.
* **No networking.** Emscripten's socket emulation needs a WebSocket relay, and
  its better path (`-sPROXY_POSIX_SOCKETS`) requires `-sPROXY_TO_PTHREAD`, which
  Qt does not support. The clean route is a WebSocket backed `Sock`: that class
  is fully virtual and `CreateSock` in `netbase.h` is a swappable
  `std::function`, so no fork of the net layer is needed.
* **No wallet.** SQLite is not built in.
* **No GUI.** Core requires Qt 6.2 or newer, and Qt 6 ships prebuilt
  `wasm_multithread` binaries, so this is reachable, but it is not done here.
* **Exception catching is off.** Emscripten's default. Real workloads need
  `-fexceptions` or `-fwasm-exceptions`.

## Build

Needs `cmake`, `git`, `python3` and system Boost headers. Everything else is
fetched.

```sh
./build.sh          # browser target, output lands in web/
```

```sh
./build.sh node     # Node target, uses NODERAWFS for real filesystem access
```

## Test

```sh
python3 test/browser_test.py 330
```

Serves `web/` with `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`, drives headless Chromium through
Playwright, and fails unless the run exits 0 at the expected height. Both
headers are mandatory: SharedArrayBuffer is gated on cross-origin isolation and
the script verification threads are gated on SharedArrayBuffer.

To serve the demo by hand instead:

```sh
python3 web/serve.py web
```

## Five things that each stopped the build

Written down because none of them is guessable from the symptom.

1. **Boost poisons the include path.** If `find_package(Boost)` resolves to
   `/usr/include`, the host glibc headers shadow Emscripten's musl and every
   translation unit fails on `bits/libc-header-start.h`. `build.sh` stages a
   prefix containing nothing but Boost.
2. **`HAVE_IFADDRS` is detected, and it crashes.** Emscripten's `getifaddrs`
   compiles and links, then opens a netlink socket that SOCKFS cannot create, so
   `RandAddStaticEnv` dies before the first log line. See
   `patches/0001-emscripten-skip-getifaddrs.patch`.
3. **`-pthread` must be in `CMAKE_CXX_FLAGS`.** Passed through Core's
   `APPEND_CXXFLAGS` it arrives after CMake has probed the compiler ABI and
   pinned the single threaded system libraries, and `wasm-ld` then rejects
   `--shared-memory` because `cxa_guard.o` has no atomics.
4. **libevent is not actually required.** It is only looked for when the daemon,
   GUI, CLI, tests or bench targets are on. `BUILD_UTIL_CHAINSTATE=ON` with the
   rest off needs no libevent, no Qt and no SQLite.
5. **emsdk's downloader hangs on IPv6-blackholed hosts.** `tools/sitecustomize.py`
   pins `getaddrinfo` to IPv4 and `build.sh` puts it on `PYTHONPATH`.

## Layout

```
build.sh                 end to end build
patches/                 the single upstream patch
tools/sitecustomize.py   IPv4 pin for emsdk downloads
web/                     demo page, COOP/COEP server, block fixture
test/browser_test.py     headless Chromium check
```

## License

Build scripts here are MIT. Bitcoin Core is MIT and is fetched, not vendored.
