# bitcoin-core-wasm

Bitcoin Core compiled to WebAssembly and running in a browser: both the
validation engine on its own, and `bitcoin-qt`, the full Qt application with its
node and wallet. Not a reimplementation and not a subset. This is
bitcoin/bitcoin at tag `v31.1` cross compiled with Emscripten, with three small
patches, none of which touch consensus, validation or the wallet.

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

* **No persistence.** The filesystem is MEMFS plus an Emscripten preload, both
  of which are gone on reload. LevelDB over OPFS is the next piece of work and is
  untested.
* **Desktop browsers only, and only Chromium is tested.** Firefox and Safari have
  never been tried. The page refuses to start on a phone before downloading
  anything.
* **No networking.** Emscripten's socket emulation needs a WebSocket relay, and
  its better path (`-sPROXY_POSIX_SOCKETS`) requires `-sPROXY_TO_PTHREAD`, which
  Qt does not support. The clean route is a WebSocket backed `Sock`: that class
  is fully virtual and `CreateSock` in `netbase.h` is a swappable
  `std::function`, so no fork of the net layer is needed.

## Build

Needs `cmake`, `git`, `python3` and system Boost headers. Everything else is
fetched, including Emscripten and Qt.

The validation engine on its own:

```sh
./build.sh          # browser target, output lands in web/
```

```sh
./build.sh node     # Node target, uses NODERAWFS for real filesystem access
```

The full application. First mine the chain that gets baked in, then build
against it, then stage it into a web root with content-hashed filenames:

```sh
./make-regtest-chain.sh
```

```sh
./build-gui.sh build/preload
```

```sh
./deploy.sh build/gui/bin /path/to/webroot/bitcoin-core-browser
```

`make-regtest-chain.sh` also rewrites the tip timestamp inside
`web-gui/demo-clock.js`. That file is linked with `--pre-js` and shifts the clock
the module sees to just after the last block: the chain never gains another one,
and Core's window declares itself out of sync whenever the tip is more than 90
minutes old. `-maxtipage` does not help, that governs the node's view of initial
block download while the modal is driven by the GUI's own constant.

Serving it needs `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`, or the browser withholds
SharedArrayBuffer and the script verification threads never start.

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

## The application build

Beyond everything below, the Qt build needed:

* **Qt 6.11.2 with Emscripten 4.0.7 exactly.** Each Qt minor version targets one
  Emscripten version. Qt publishes prebuilt `wasm_multithread` binaries, so Qt
  itself never has to be built from source.
* **A platform plugin branch.** Qt for WebAssembly ships only `qwasm`, so Core's
  static plugin list has no `QMinimalIntegrationPlugin` to fall back on.
* **`-lembind`** and six exported runtime methods that Qt's own build system adds
  automatically and Core's does not.
* **`-fexceptions`.** `AppInitMain` calls `std::filesystem::file_size` and catches
  the throw. With Emscripten's default a throw is an immediate abort, so Core
  died just after painting its splash screen.
* **`-sASYNCIFY`.** Core opens modal dialogs with `exec()`, which needs a nested
  event loop a browser does not have.
* **`-sDYNAMIC_EXECUTION=0`.** Removes the two `new Function` calls from the glue
  code, so the page runs under a Content Security Policy with no `'unsafe-eval'`.
* **The payment server compiled out.** It listens on a local socket to route
  `bitcoin:` clicks into a running process. Without a socket the user is greeted
  by an error dialog.

## Five more, from the engine build

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
build.sh                 validation engine, browser and node targets
build-gui.sh             the full Qt application, node and wallet included
make-regtest-chain.sh    mines the chain that gets baked into the application
deploy.sh                stages a build into a web root, content-hashed
patches/                 three patches against Bitcoin Core
tools/sitecustomize.py   IPv4 pin for emsdk downloads
web/                     validation engine demo page and COOP/COEP server
web-gui/                 the application's page, loader and clock shim
test/browser_test.py     headless Chromium check for the validation engine
```

## License

Build scripts here are MIT. Bitcoin Core is MIT and is fetched, not vendored.
