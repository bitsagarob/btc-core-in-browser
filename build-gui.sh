#!/bin/bash
# Build bitcoin-qt, Bitcoin Core's Qt application, for WebAssembly.
#
#   ./build-gui.sh [path/to/preload-datadir]
#
# With a datadir argument, that directory is baked into the binary as an
# Emscripten preload and mounted at /data/regtest, so the node comes up with a
# chain and a wallet already present. make-regtest-chain.sh produces one.
#
# Needs: cmake, git, python3, system Boost headers, and enough disk for Qt
# (about 3 GB) plus the build tree.
set -euo pipefail

CORE_TAG="v31.1"
CORE_COMMIT="9be056a8a72b624dae9623b2f7bded92c2a21c91"  # tags move, commits do not
EMSDK_COMMIT="c59d6e841da55c2c21af32004c4c173cbd1c0f10"
EMSDK_VERSION="4.0.7"
QT_VERSION="6.11.2"          # each Qt minor targets one Emscripten version, do not move one alone
AQT_VERSION="3.3.0"
SQLITE_ZIP_URL="https://sqlite.org/2025/sqlite-amalgamation-3500400.zip"
SQLITE_ZIP_SHA="1d3049dd0f830a025a53105fc79fd2ab9431aea99e137809d064d8ee8356b032"
PRELOAD="${1:-}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
EMSDK="${EMSDK:-$BUILD/emsdk}"
QT="${QT:-$BUILD/Qt}"
PREFIX="$BUILD/prefix-wasm"
case "$ROOT" in
  *" "*) echo "a path with a space in it breaks the Emscripten link line"; exit 1 ;;
esac
mkdir -p "$BUILD" "$PREFIX/lib" "$PREFIX/include"

# ---------------------------------------------------------------- emsdk
if [ ! -x "$EMSDK/upstream/emscripten/emcc" ]; then
  echo "==> installing emsdk $EMSDK_VERSION"
  if [ ! -d "$EMSDK" ]; then
    git clone https://github.com/emscripten-core/emsdk.git "$EMSDK.partial"
    git -C "$EMSDK.partial" checkout -q "$EMSDK_COMMIT"
    mv "$EMSDK.partial" "$EMSDK"
  fi
  FORCE_IPV4="${FORCE_IPV4:-1}" PYTHONPATH="$ROOT/tools" "$EMSDK/emsdk" install "$EMSDK_VERSION"
  FORCE_IPV4="${FORCE_IPV4:-1}" PYTHONPATH="$ROOT/tools" "$EMSDK/emsdk" activate "$EMSDK_VERSION"
fi
# shellcheck disable=SC1091
source "$EMSDK/emsdk_env.sh" >/dev/null

# ------------------------------------------------------------------- Qt
# Qt publishes prebuilt wasm_multithread binaries, so Qt itself never has to be
# built from source. The host build is needed too: it supplies moc, rcc and the
# Linguist tools that cross-compiling uses.
if [ ! -d "$QT/$QT_VERSION/wasm_multithread" ]; then
  echo "==> installing Qt $QT_VERSION (host and wasm)"
  [ -d "$BUILD/venv-aqt" ] || python3 -m venv "$BUILD/venv-aqt"
  "$BUILD/venv-aqt/bin/pip" install -q "aqtinstall==$AQT_VERSION"
  FORCE_IPV4="${FORCE_IPV4:-1}" PYTHONPATH="$ROOT/tools" "$BUILD/venv-aqt/bin/aqt" install-qt linux desktop "$QT_VERSION" linux_gcc_64 -O "$QT"
  FORCE_IPV4="${FORCE_IPV4:-1}" PYTHONPATH="$ROOT/tools" "$BUILD/venv-aqt/bin/aqt" install-qt all_os wasm "$QT_VERSION" wasm_multithread -O "$QT"
fi
QT_WASM="$QT/$QT_VERSION/wasm_multithread"
QT_HOST="$QT/$QT_VERSION/gcc_64"

# -------------------------------------------------------------- libevent
# Required as soon as BUILD_GUI is on, even though the browser build never
# starts the RPC server that uses it.
if [ ! -f "$PREFIX/lib/libevent_core.a" ]; then
  echo "==> building libevent for wasm"
  [ -d "$BUILD/libevent" ] || git clone --depth 1 --branch release-2.1.12-stable \
    https://github.com/libevent/libevent.git "$BUILD/libevent"
  emcmake cmake -B "$BUILD/build-libevent" -S "$BUILD/libevent" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-pthread $MAPFLAGS" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DEVENT__LIBRARY_TYPE=STATIC \
    -DEVENT__DISABLE_OPENSSL=ON -DEVENT__DISABLE_MBEDTLS=ON \
    -DEVENT__DISABLE_BENCHMARK=ON -DEVENT__DISABLE_TESTS=ON \
    -DEVENT__DISABLE_REGRESS=ON -DEVENT__DISABLE_SAMPLES=ON
  cmake --build "$BUILD/build-libevent" -j"$(nproc)"
  cmake --install "$BUILD/build-libevent"
fi

# ---------------------------------------------------------------- sqlite
# The descriptor wallet needs it. The amalgamation compiles to wasm unchanged.
if [ ! -f "$PREFIX/lib/libsqlite3.a" ]; then
  echo "==> building sqlite for wasm"
  zip="$BUILD/$(basename "$SQLITE_ZIP_URL")"
  [ -f "$zip" ] || curl -sSL -o "$zip" "$SQLITE_ZIP_URL"
  echo "$SQLITE_ZIP_SHA  $zip" | sha256sum -c - || { rm -f "$zip"; exit 1; }
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$BUILD"
  s="$BUILD/$(basename "${zip%.zip}")"
  emcc -O2 -pthread -fexceptions -c "$s/sqlite3.c" -o "$s/sqlite3.o" \
    -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_THREADSAFE=1 \
    -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_DISABLE_DIRSYNC=1
  emar rcs "$PREFIX/lib/libsqlite3.a" "$s/sqlite3.o"
  cp "$s/sqlite3.h" "$s/sqlite3ext.h" "$PREFIX/include/"
fi

# Boost, in its own prefix. Pointing find_package at /usr/include puts the host
# glibc headers ahead of Emscripten's musl and every translation unit fails on
# bits/libc-header-start.h.
#
# The version is read out of version.hpp rather than asserted. Writing a number
# into the generated BoostConfig.cmake means Core's find_package(Boost 1.74.0)
# check passes against whatever the host actually has, which on an older distro
# is a failure two hundred compile errors later.
BOOST_SRC="${BOOST_SRC:-/usr/include/boost}"
[ -f "$BOOST_SRC/version.hpp" ] || { echo "no Boost headers at $BOOST_SRC"; exit 1; }
_bv="$(sed -n 's/^#define BOOST_VERSION \([0-9]*\).*/\1/p' "$BOOST_SRC/version.hpp")"
[ -n "$_bv" ] || { echo "cannot read BOOST_VERSION from $BOOST_SRC/version.hpp"; exit 1; }
BOOST_VER="$((_bv / 100000)).$((_bv / 100 % 1000)).$((_bv % 100))"
BOOST_PREFIX="$BUILD/boost-$BOOST_VER"
if [ ! -d "$BOOST_PREFIX" ]; then
  mkdir -p "$BOOST_PREFIX/include" "$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VER"
  ln -sfn "$BOOST_SRC" "$BOOST_PREFIX/include/boost"
  cat > "$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VER/BoostConfig.cmake" <<EOF
set(Boost_VERSION $BOOST_VER)
set(Boost_INCLUDE_DIR "$BOOST_PREFIX/include" CACHE PATH "")
if(NOT TARGET Boost::headers)
  add_library(Boost::headers INTERFACE IMPORTED)
  set_target_properties(Boost::headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "$BOOST_PREFIX/include")
endif()
set(Boost_FOUND TRUE)
EOF
  cat > "$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VER/BoostConfigVersion.cmake" <<EOF
set(PACKAGE_VERSION "$BOOST_VER")
if(PACKAGE_FIND_VERSION VERSION_LESS_EQUAL PACKAGE_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
EOF
fi

# ------------------------------------------------------------------ core
CORE="$BUILD/core"
if [ ! -d "$CORE" ]; then
  echo "==> cloning bitcoin core $CORE_TAG"
  git clone --depth 1 --branch "$CORE_TAG" https://github.com/bitcoin/bitcoin.git "$CORE.partial"
  for patch in "$ROOT"/patches/*.patch; do
    echo "    applying $(basename "$patch")"
    git -C "$CORE.partial" apply "$patch"
  done
  have="$(git -C "$CORE.partial" rev-parse HEAD)"
  [ "$have" = "$CORE_COMMIT" ] || {
    echo "$CORE_TAG resolved to $have, expected $CORE_COMMIT"; rm -rf "$CORE.partial"; exit 1; }
  mv "$CORE.partial" "$CORE"
fi

# Without these the absolute checkout path ends up in the binary, through Boost
# header paths among others, so two people building identical inputs in
# different directories get different bytes.
MAPFLAGS="-ffile-prefix-map=$BUILD=/build -ffile-prefix-map=$BOOST_PREFIX=/boost"

# ----------------------------------------------------------------- flags
# Every flag below is explained in the README, under "The application build".
LDFLAGS="-sPTHREAD_POOL_SIZE=40 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=4GB"
LDFLAGS="$LDFLAGS -sINITIAL_MEMORY=268435456 -sSTACK_SIZE=4194304"
LDFLAGS="$LDFLAGS -sFORCE_FILESYSTEM=1 -sASSERTIONS=0 -sDYNAMIC_EXECUTION=0"
LDFLAGS="$LDFLAGS -sASYNCIFY=1 -sASYNCIFY_STACK_SIZE=131072 -fexceptions"
LDFLAGS="$LDFLAGS --pre-js $ROOT/web-gui/demo-clock.js -lembind"
LDFLAGS="$LDFLAGS -sEXPORTED_RUNTIME_METHODS=UTF16ToString,stringToUTF16,JSEvents,specialHTMLTargets,FS,callMain"
LDFLAGS="$LDFLAGS -sEXPORTED_FUNCTIONS=_main,__embind_initialize_bindings"
[ -n "$PRELOAD" ] && LDFLAGS="$LDFLAGS --preload-file $(cd "$PRELOAD" && pwd)@/data/regtest"

OUT="$BUILD/gui"
cmake -B "$OUT" -S "$CORE" \
  -DCMAKE_TOOLCHAIN_FILE="$QT_WASM/lib/cmake/Qt6/qt.toolchain.cmake" \
  -DQT_HOST_PATH="$QT_HOST" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-pthread -fexceptions $MAPFLAGS" -DCMAKE_C_FLAGS="-pthread -fexceptions $MAPFLAGS" \
  -DBUILD_GUI=ON -DBUILD_DAEMON=OFF -DBUILD_CLI=OFF -DBUILD_BITCOIN_BIN=OFF \
  -DBUILD_TESTS=OFF -DBUILD_TX=OFF -DBUILD_UTIL=OFF -DBUILD_GUI_TESTS=OFF \
  -DENABLE_WALLET=ON -DENABLE_IPC=OFF -DENABLE_EXTERNAL_SIGNER=OFF \
  -DWITH_ZMQ=OFF -DWITH_CCACHE=OFF -DINSTALL_MAN=OFF \
  -DWITH_QRENCODE=OFF -DWITH_DBUS=OFF \
  -DSQLite3_INCLUDE_DIR="$PREFIX/include" -DSQLite3_LIBRARY="$PREFIX/lib/libsqlite3.a" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_PREFIX_PATH="$PREFIX;$QT_WASM" \
  -DBoost_DIR="$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VER" \
  -DAPPEND_LDFLAGS="$LDFLAGS"

cmake --build "$OUT" --target bitcoin-qt -j"$(nproc)"
ls -la "$OUT/bin"
echo
echo "next: ./deploy.sh $OUT/bin <web-dir>"
