#!/bin/bash
# Build Bitcoin Core's validation engine for WebAssembly.
#
#   ./build.sh            build the browser target into web/
#   ./build.sh node       build the node target into build/node/
#
# Needs: cmake, a system Boost (headers only), git, python3.
set -euo pipefail

CORE_TAG="${CORE_TAG:-v31.1}"
EMSDK_VERSION="${EMSDK_VERSION:-4.0.7}"
TARGET="${1:-web}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
EMSDK="${EMSDK:-$BUILD/emsdk}"
mkdir -p "$BUILD"

# ---------------------------------------------------------------- emsdk
if [ ! -x "$EMSDK/upstream/emscripten/emcc" ]; then
  echo "==> installing emsdk $EMSDK_VERSION"
  [ -d "$EMSDK" ] || git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$EMSDK"
  # PYTHONPATH shim forces IPv4; emsdk's downloader hangs on IPv6-blackholed hosts.
  PYTHONPATH="$ROOT/tools" "$EMSDK/emsdk" install "$EMSDK_VERSION"
  PYTHONPATH="$ROOT/tools" "$EMSDK/emsdk" activate "$EMSDK_VERSION"
fi
# shellcheck disable=SC1091
source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1

# ---------------------------------------------------------------- source
CORE="$BUILD/core"
if [ ! -d "$CORE" ]; then
  echo "==> cloning bitcoin core $CORE_TAG"
  git clone --depth 1 --branch "$CORE_TAG" https://github.com/bitcoin/bitcoin.git "$CORE"
  git -C "$CORE" apply "$ROOT/patches/0001-emscripten-skip-getifaddrs.patch"
fi

# ------------------------------------------------- boost, in its own prefix
# Pointing find_package(Boost) at /usr/include puts the host glibc headers
# ahead of Emscripten's musl, and every translation unit then fails on
# bits/libc-header-start.h. Give it a prefix containing nothing but boost.
BOOST_SRC="${BOOST_SRC:-/usr/include/boost}"
BOOST_PREFIX="$BUILD/boost-prefix"
BOOST_VER="${BOOST_VER:-1.83.0}"
if [ ! -d "$BOOST_PREFIX" ]; then
  echo "==> staging boost headers from $BOOST_SRC"
  [ -d "$BOOST_SRC" ] || { echo "boost headers not found at $BOOST_SRC"; exit 1; }
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

# ---------------------------------------------------------------- link flags
COMMON_LD="-sPTHREAD_POOL_SIZE=16 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=4GB"
COMMON_LD="$COMMON_LD -sINITIAL_MEMORY=134217728 -sSTACK_SIZE=4194304"
COMMON_LD="$COMMON_LD -sEXIT_RUNTIME=1 -sASSERTIONS=1"

case "$TARGET" in
  web)  OUTDIR="$BUILD/web";  LDFLAGS="$COMMON_LD -sFORCE_FILESYSTEM=1 -sENVIRONMENT=web,worker" ;;
  node) OUTDIR="$BUILD/node"; LDFLAGS="$COMMON_LD -sNODERAWFS=1" ;;
  *) echo "usage: $0 [web|node]"; exit 1 ;;
esac

# -pthread has to be in CMAKE_CXX_FLAGS, not Core's APPEND_CXXFLAGS. CMake
# detects the compiler ABI at configure time and pins the single-threaded
# system libraries, after which wasm-ld rejects --shared-memory.
emcmake cmake -B "$OUTDIR" -S "$CORE" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-pthread" -DCMAKE_C_FLAGS="-pthread" \
  -DBUILD_BITCOIN_BIN=OFF -DBUILD_DAEMON=OFF -DBUILD_CLI=OFF \
  -DBUILD_TESTS=OFF -DBUILD_TX=OFF -DBUILD_UTIL=OFF -DBUILD_GUI=OFF \
  -DENABLE_WALLET=OFF -DENABLE_IPC=OFF -DENABLE_EXTERNAL_SIGNER=OFF \
  -DWITH_ZMQ=OFF -DWITH_CCACHE=OFF -DINSTALL_MAN=OFF \
  -DBUILD_KERNEL_LIB=ON -DBUILD_UTIL_CHAINSTATE=ON \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  -DBoost_DIR="$BOOST_PREFIX/lib/cmake/Boost-$BOOST_VER" \
  -DAPPEND_LDFLAGS="$LDFLAGS"

cmake --build "$OUTDIR" --target bitcoin-chainstate -j"$(nproc)"

if [ "$TARGET" = web ]; then
  cp "$OUTDIR"/bin/bitcoin-chainstate.js "$OUTDIR"/bin/bitcoin-chainstate.wasm "$ROOT/web/"
  echo "==> web/ updated"
fi
ls -la "$OUTDIR/bin"
