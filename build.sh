#!/bin/bash
# Build Bitcoin Core's validation engine for WebAssembly.
#
#   ./build.sh            build the browser target into web/
#   ./build.sh node       build the node target into build/node/
#
# Needs: cmake, a system Boost (headers only), git, python3.
set -euo pipefail

# Qt's resource compiler stamps the modification time of every file it packs
# into the binary, including translation files generated during this build. Both
# rcc and the wider reproducible-builds convention read this.
export SOURCE_DATE_EPOCH=1231006505

CORE_TAG="v31.1"
CORE_COMMIT="9be056a8a72b624dae9623b2f7bded92c2a21c91"  # tags move, commits do not
EMSDK_COMMIT="c59d6e841da55c2c21af32004c4c173cbd1c0f10"
EMSDK_VERSION="4.0.7"
TARGET="${1:-web}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
EMSDK="${EMSDK:-$BUILD/emsdk}"
case "$ROOT" in
  *" "*) echo "a path with a space in it breaks the Emscripten link line"; exit 1 ;;
esac
mkdir -p "$BUILD"

# ---------------------------------------------------------------- emsdk
if [ ! -x "$EMSDK/upstream/emscripten/emcc" ]; then
  echo "==> installing emsdk $EMSDK_VERSION"
  if [ ! -d "$EMSDK" ]; then
    git clone https://github.com/emscripten-core/emsdk.git "$EMSDK.partial"
    git -C "$EMSDK.partial" checkout -q "$EMSDK_COMMIT"
    mv "$EMSDK.partial" "$EMSDK"
  fi
  # PYTHONPATH shim forces IPv4; emsdk's downloader hangs on IPv6-blackholed hosts.
  FORCE_IPV4="${FORCE_IPV4:-1}" PYTHONPATH="$ROOT/tools" "$EMSDK/emsdk" install "$EMSDK_VERSION"
  FORCE_IPV4="${FORCE_IPV4:-1}" PYTHONPATH="$ROOT/tools" "$EMSDK/emsdk" activate "$EMSDK_VERSION"
fi
# shellcheck disable=SC1091
source "$EMSDK/emsdk_env.sh" >/dev/null

# ---------------------------------------------------------------- source
CORE="$BUILD/core"
if [ ! -d "$CORE" ]; then
  echo "==> cloning bitcoin core $CORE_TAG"
  git clone --depth 1 --branch "$CORE_TAG" https://github.com/bitcoin/bitcoin.git "$CORE.partial"
  # All of them, including the two that only touch src/qt. build-gui.sh shares
  # this checkout, and applying a different set here left it half patched: the
  # Qt build then skipped its own patches and produced a bitcoin-qt with no
  # platform plugin, forty minutes later, with nothing said.
  for patch in "$ROOT"/patches/*.patch; do
    git -C "$CORE.partial" apply "$patch"
  done
  # Rename last, so an interrupted clone or a failed patch cannot leave a
  # directory that every later run treats as finished.
  have="$(git -C "$CORE.partial" rev-parse HEAD)"
  [ "$have" = "$CORE_COMMIT" ] || {
    echo "$CORE_TAG resolved to $have, expected $CORE_COMMIT"; rm -rf "$CORE.partial"; exit 1; }
  mv "$CORE.partial" "$CORE"
fi

# Qt's resource compiler embeds the modification time of every file it packs, so
# two clones made at different moments produce different bytes from identical
# sources. Pin them, to the timestamp in the genesis block.
find "$CORE" -exec touch -h -d @1231006505 {} +

# Boost, pinned and fetched, in its own prefix.
#
# Two reasons it is not the host's headers. Pointing find_package at
# /usr/include puts the host glibc headers ahead of Emscripten's musl and every
# translation unit fails on bits/libc-header-start.h. And a build whose headers
# come from whatever the distro ships cannot produce the same bytes twice on two
# machines. Only the headers are extracted; nothing here links a Boost library.
BOOST_VER="1.83.0"
BOOST_TARBALL_URL="https://archives.boost.io/release/1.83.0/source/boost_1_83_0.tar.gz"
BOOST_TARBALL_SHA="c0685b68dd44cc46574cce86c4e17c0f611b15e195be9848dfd0769a0a207628"
BOOST_PREFIX="$BUILD/boost-$BOOST_VER"
if [ ! -d "$BOOST_PREFIX" ]; then
  echo "==> fetching boost $BOOST_VER"
  boost_tar="$BUILD/boost.tar.gz"
  [ -f "$boost_tar" ] || curl -sSL -o "$boost_tar" "$BOOST_TARBALL_URL"
  echo "$BOOST_TARBALL_SHA  $boost_tar" | sha256sum -c - || { rm -f "$boost_tar"; exit 1; }
  rm -rf "$BOOST_PREFIX.partial"
  mkdir -p "$BOOST_PREFIX.partial/include" "$BOOST_PREFIX.partial/lib/cmake/Boost-$BOOST_VER"
  tar -xzf "$boost_tar" -C "$BOOST_PREFIX.partial/include" --strip-components=1 \
    "boost_${BOOST_VER//./_}/boost"
  cat > "$BOOST_PREFIX.partial/lib/cmake/Boost-$BOOST_VER/BoostConfig.cmake" <<EOF
set(Boost_VERSION $BOOST_VER)
set(Boost_INCLUDE_DIR "$BOOST_PREFIX/include" CACHE PATH "")
if(NOT TARGET Boost::headers)
  add_library(Boost::headers INTERFACE IMPORTED)
  set_target_properties(Boost::headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "$BOOST_PREFIX/include")
endif()
set(Boost_FOUND TRUE)
EOF
  cat > "$BOOST_PREFIX.partial/lib/cmake/Boost-$BOOST_VER/BoostConfigVersion.cmake" <<EOF
set(PACKAGE_VERSION "$BOOST_VER")
if(PACKAGE_FIND_VERSION VERSION_LESS_EQUAL PACKAGE_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
EOF
  mv "$BOOST_PREFIX.partial" "$BOOST_PREFIX"
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
  -DCMAKE_CXX_FLAGS="-pthread $MAPFLAGS" -DCMAKE_C_FLAGS="-pthread $MAPFLAGS" \
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
