# WebP codec provenance

Built on 2026-10-29 from unmodified official release archives. No Homebrew code
or binary was copied. The runtime needs only macOS system libraries.

## Sources

libwebp 1.6.0, including libsharpyuv 0.4.2:

- Official download page: https://developers.google.com/speed/webp/download
- Official build documentation: https://developers.google.com/speed/webp/docs/compiling
- Source archive: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
- SHA-256: `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`
- Hash measured from the official HTTPS download and pinned by the build script.
- BSD license, authors, and patent grant: `licenses/libwebp-COPYING`,
  `licenses/libwebp-AUTHORS`, and `licenses/libwebp-PATENTS`.

libpng 1.6.59:

- Official project page and published checksum: https://www.libpng.org/pub/png/libpng.html
- Official project release download: https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.gz
- SHA-256: `86a3e4b501f7f50e392c4e456ea158893e9a595b1c63eb88c7bb9f6cf8772dad`
- Hash matches the value published by the official project page.
- PNG Reference Library license: `licenses/libpng-LICENSE`.

System zlib is dynamically linked, not redistributed.

## Packaged executable

- File: `cwebp`
- Version: libwebp 1.6.0; libsharpyuv 0.4.2.
- Mach-O architecture: arm64 only.
- `LC_BUILD_VERSION`: platform macOS, `minos 13.0`, SDK 26.5.
- Size: 624,560 bytes.
- SHA-256: `24b0f3284fffaee42783bd70edf30549e63473c76347190b811c1989f028dd52`.
- Direct runtime dependencies: `/usr/lib/libSystem.B.dylib`, `/usr/lib/libz.1.dylib`.
- No `LC_RPATH`, `@rpath`, Homebrew dependency, or adjacent shared library.
- Ad hoc signature passes `codesign --verify --strict`.

Built with Apple Clang 21.0.0 (`clang-2100.1.1.101`) and macOS SDK 26.5.
Compiler flags: `-O3 -arch arm64 -mmacosx-version-min=13.0 -isysroot <SDK>`.
Linker flags: `-arch arm64 -mmacosx-version-min=13.0 -isysroot <SDK> -Wl,-dead_strip`.
Both projects use `--disable-shared --enable-static`; optional external image
formats and UI libraries are disabled. See `tools/codecs/webp/build.sh` in the
source repository for every configure argument and the complete pinned build.
Repeatable source builds use the pinned archives; different Clang/SDK versions
may produce different executable hashes.
Two clean builds in separate build directories with this toolchain produced
byte-identical encoders with the SHA-256 shown above; see
`tools/codecs/webp/reproducibility-report.json`.

## Verification

On macOS 26.6.2 arm64, the packaged and relocated executables encoded valid WebP.
Lossless RGBA decoding reproduced every source byte, including hidden RGB and
alpha. Lossy and near-lossless outputs decoded with exact alpha and correct
dimensions. A standalone copy under an app-like path containing spaces ran with
a clean environment and no Homebrew paths. The 64x48 parent PNG probe encoded and
decoded with alpha as well. The codec-only verification script and detailed
reports live in `tools/codecs/webp/` in the source repository.

The macOS 13.0 deployment target and dependency audit are verified; an actual
macOS 13 runtime was not available for execution testing.
