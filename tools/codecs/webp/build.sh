#!/bin/bash
# Build only this codec. Requires Apple's Command Line Tools; no package manager.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LIBS SDKROOT
export PKG_CONFIG=/usr/bin/false PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=
export CONFIG_SITE=/dev/null ZERO_AR_DATE=1

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DEST="$ROOT/Resources/Codecs/webp"
mkdir -p "$HERE/downloads" "$HERE/work" "$HERE/bin" "$DEST/licenses"
BUILD="$(mktemp -d "$HERE/work/build.XXXXXX")"
export TMPDIR="$BUILD/tmp"
mkdir -p "$TMPDIR"
JOBS="${WEBP_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"

fetch() {
  local name="$1" url="$2" expected="$3" actual
  if [ ! -f "$HERE/downloads/$name" ]; then
    curl --fail --location --retry 2 --proto '=https' --proto-redir '=https' \
      "$url" --output "$HERE/downloads/$name.part"
    mv "$HERE/downloads/$name.part" "$HERE/downloads/$name"
  fi
  actual="$(shasum -a 256 "$HERE/downloads/$name" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "SHA-256 mismatch for $name: $actual" >&2
    exit 1
  fi
  tar -xzf "$HERE/downloads/$name" -C "$BUILD"
}

fetch libwebp-1.6.0.tar.gz \
  https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz \
  e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
fetch libpng-1.6.59.tar.gz \
  https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.gz \
  86a3e4b501f7f50e392c4e456ea158893e9a595b1c63eb88c7bb9f6cf8772dad

export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CFLAGS="-O3 -arch arm64 -mmacosx-version-min=13.0 -isysroot $SDKROOT"
export CPPFLAGS=
export LDFLAGS="-arch arm64 -mmacosx-version-min=13.0 -isysroot $SDKROOT -Wl,-dead_strip"
PREFIX="$BUILD/png-prefix"
(
  cd "$BUILD/libpng-1.6.59" || exit 1
  ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-dependency-tracking --enable-arm-neon=yes || exit 1
  make -j "$JOBS" || exit 1
  make install || exit 1
) > "$BUILD/libpng-build.log" 2>&1 || { tail -80 "$BUILD/libpng-build.log"; exit 1; }

(
  cd "$BUILD/libwebp-1.6.0" || exit 1
  ./configure --prefix="$BUILD/webp-prefix" --disable-shared --enable-static \
    --disable-dependency-tracking --disable-libwebpmux \
    --disable-libwebpdecoder --disable-libwebpextras \
    --disable-jpeg --disable-tiff --disable-gif --disable-gl --disable-sdl --disable-wic \
    --with-pngincludedir="$PREFIX/include" --with-pnglibdir="$PREFIX/lib" || exit 1
  make -j "$JOBS" || exit 1
) > "$BUILD/libwebp-build.log" 2>&1 || { tail -80 "$BUILD/libwebp-build.log"; exit 1; }

install -m 755 "$BUILD/libwebp-1.6.0/examples/cwebp" "$BUILD/cwebp"
install -m 755 "$BUILD/libwebp-1.6.0/examples/dwebp" "$BUILD/dwebp"
for binary in "$BUILD/cwebp" "$BUILD/dwebp"; do
  strip -x "$binary"
  codesign --force --sign - --timestamp=none "$binary"
  codesign --verify --strict "$binary"
  test "$(lipo -archs "$binary")" = arm64
  test "$(otool -l "$binary" | awk '$1 == "minos" {print $2}')" = 13.0
  otool -L "$binary" | tail -n +2 | awk '
    $1 != "/usr/lib/libz.1.dylib" && $1 != "/usr/lib/libSystem.B.dylib" {bad=1; print "Unexpected dependency: " $1}
    END {exit bad}'
done
mv "$BUILD/cwebp" "$DEST/cwebp"
mv "$BUILD/dwebp" "$HERE/bin/dwebp"
cp "$BUILD/libwebp-1.6.0/COPYING" "$DEST/licenses/libwebp-COPYING"
cp "$BUILD/libwebp-1.6.0/PATENTS" "$DEST/licenses/libwebp-PATENTS"
cp "$BUILD/libwebp-1.6.0/AUTHORS" "$DEST/licenses/libwebp-AUTHORS"
cp "$BUILD/libpng-1.6.59/LICENSE" "$DEST/licenses/libpng-LICENSE"

{
  printf 'Build directory: %s\n' "$BUILD"
  "$CC" --version
  xcrun --sdk macosx --show-sdk-version
  "$DEST/cwebp" -version
  file "$DEST/cwebp"
  otool -L "$DEST/cwebp"
  otool -l "$DEST/cwebp" | awk '/LC_BUILD_VERSION/{n=6} n{print; n--}'
  shasum -a 256 "$DEST/cwebp" "$HERE/bin/dwebp"
  stat -f '%z bytes %N' "$DEST/cwebp" "$HERE/bin/dwebp"
} | tee "$HERE/build-report.txt"
