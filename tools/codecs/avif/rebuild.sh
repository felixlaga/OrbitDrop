#!/bin/bash
# Build only the vendored AVIF helper. No installs outside this codec directory.
set -euo pipefail
codec_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$codec_dir/../../.." && pwd)"
destination="$project_dir/Resources/Codecs/avif"
export MACOSX_DEPLOYMENT_TARGET=13.0
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'Rebuild on an Apple Silicon Mac with Xcode Command Line Tools.' >&2
  exit 1
fi
download() {
  local url="$1" output="$2" expected="$3"
  if [[ ! -f "$output" ]]; then curl -fLsS --retry 2 "$url" -o "$output"; fi
  local actual
  actual="$(shasum -a 256 "$output" | cut -d ' ' -f 1)"
  if [[ "$actual" != "$expected" ]]; then echo "SHA-256 mismatch: $output" >&2; exit 1; fi
}
verify_commit() {
  local folder="$1" expected="$2"
  if [[ "$(git -C "$folder" rev-parse HEAD)" != "$expected" ]]; then
    echo "Upstream dependency commit mismatch: $folder" >&2; exit 1
  fi
}
download 'https://github.com/Kitware/CMake/releases/download/v4.0.3/cmake-4.0.3-macos-universal.tar.gz' \
  "$codec_dir/cmake-4.0.3-macos-universal.tar.gz" '4e85de4daf1c3e82d7dc6b8ba5683972944b466343aeb9c327a742437bb3ce9a'
download 'https://github.com/AOMediaCodec/libavif/archive/refs/tags/v1.4.2.tar.gz' \
  "$codec_dir/libavif-1.4.2.tar.gz" '2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d'
[[ -d "$codec_dir/cmake-4.0.3-macos-universal" ]] || tar -xzf "$codec_dir/cmake-4.0.3-macos-universal.tar.gz" -C "$codec_dir"
[[ -d "$codec_dir/libavif-1.4.2" ]] || tar -xzf "$codec_dir/libavif-1.4.2.tar.gz" -C "$codec_dir"
cmake="$codec_dir/cmake-4.0.3-macos-universal/CMake.app/Contents/bin/cmake"
build="$codec_dir/build"
"$cmake" -S "$codec_dir/libavif-1.4.2" -B "$build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_FLAGS=-mmacosx-version-min=13.0 -DCMAKE_CXX_FLAGS=-mmacosx-version-min=13.0 \
  -DBUILD_SHARED_LIBS=OFF -DAVIF_BUILD_APPS=ON -DAVIF_BUILD_MAN_PAGES=OFF \
  -DAVIF_CODEC_AOM=LOCAL -DAVIF_CODEC_AOM_DECODE=OFF -DAVIF_LIBYUV=OFF \
  -DAVIF_LIBSHARPYUV=OFF -DAVIF_JPEG=LOCAL -DAVIF_ZLIBPNG=LOCAL -DAVIF_LIBXML2=OFF
verify_commit "$build/_deps/libaom-src" '03087864cf4bea6abb0d28f95cf7843511413d8f'
verify_commit "$build/_deps/libpng-src" '3061454d980de7d53608f594194cfac722721d2a'
verify_commit "$build/_deps/zlib-src" 'da607da739fa6047df13e66a2af6b8bec7c2a498'
verify_commit "$build/_deps/libargparse-src" 'ee74d1b53bd680748af14e737378de57e2a0a954'
"$cmake" --build "$build" --target avifenc --parallel 8
verify_commit "$build/libjpeg/src/libjpeg" '9217719d3a58633923b096af4c1d50d304768a64'
mkdir -p "$destination"
candidate="$destination/.avifenc-rebuild"
trap 'rm -f "$candidate"' EXIT
cp "$build/avifenc" "$candidate"
strip -x "$candidate"
codesign --force --sign - --identifier avifenc "$candidate"
codesign --verify --strict "$candidate"
if [[ "$(lipo -archs "$candidate")" != arm64 ]] || \
   [[ "$(otool -l "$candidate" | awk '/minos/{print $2}')" != 13.0 ]] || \
   [[ "$(otool -L "$candidate" | tail -n +2 | awk '{print $1}')" != /usr/lib/libSystem.B.dylib ]]; then
  echo 'Unexpected architecture, deployment target, or runtime dependency.' >&2
  exit 1
fi
mv -f "$candidate" "$destination/avifenc"
"$destination/avifenc" --version
otool -L "$destination/avifenc"
shasum -a 256 "$destination/avifenc"
echo 'Preserve the checked-in licenses. If the binary hash changed, update provenance.json after auditing it.'
