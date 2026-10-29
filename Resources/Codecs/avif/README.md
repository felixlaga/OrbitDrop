# Portable AVIF encoder

`avifenc` is libavif 1.4.2 with libaom 3.14.1, built for Apple Silicon
(`arm64`, Mach-O minimum macOS 13.0). All non-system libraries are linked
statically; the only dynamic dependency is `/usr/lib/libSystem.B.dylib`.
No Homebrew, additional dylibs, environment variables, network access, or
system installation is required to run it. The binary is ad-hoc signed.

Use absolute paths with Foundation `Process.executableURL` and an argument array:

```text
avifenc -q 80 --qalpha 100 --speed 6 --jobs 2 --ignore-exif --ignore-xmp input.png output.avif
```

Quality is 0–100. Lossless alpha is requested explicitly. Inputs are PNG,
JPEG, or Y4M; a normalized sRGB PNG intermediate is appropriate for the app.
Images may contain alpha. For screen content, the default PNG output sampling
is YUV444. `--lossless` is available if full lossless encoding is desired;
`-q 100` alone does not necessarily make RGB-to-YUV conversion lossless.
The binary contains an AV1 encoder only, not an AVIF decoder. It writes progress
to stdout and diagnostics to stderr; drain both streams or redirect to files
to avoid blocking a synchronous `Process`. Use the termination status as the
primary error indicator and validate the resulting file before replacing output.

The 2026-10-29 probe encoded a 64×48 RGBA PNG into a 633-byte AVIF with
`ftypavif` at bytes 4–11. Apple's independent ImageIO decoder returned
`public.avif`, 64×48, and alpha values spanning 128–255. The binary was copied
to a directory containing spaces and Japanese characters and invoked with
`env -i PATH=/usr/bin:/bin`. Full evidence is in `tools/codecs/probes`.
Execution was tested on macOS 26.6.2; macOS 13 compatibility is established
by the deployment target and dependency audit, not a macOS 13 runtime test.

Package this complete directory, including `licenses` and `provenance.json`.
Keep the executable bit. Sign this helper with the application's signing
identity before signing the enclosing app for distribution. Its path can be
`MyApp.app/Contents/Resources/Codecs/avif/avifenc`. No install-name rewriting or
`DYLD_LIBRARY_PATH` is needed. No notarization or Developer ID signature has
been performed by this codec task.

Built from unmodified official upstream source, using the pinned versions and
commits in `provenance.json`. Rebuild using `tools/codecs/avif/rebuild.sh` on an
Apple Silicon Mac with Xcode Command Line Tools. It downloads a local CMake
and official source repositories only; it performs no system installation.
The build also fetches libargparse for upstream CMake configuration, but
avifenc does not link it. Source downloads and build caches are not needed in
the shipped app. CMake is a build tool and is not included in this package.

Attribution: this software includes libavif, libaom, libpng, zlib,
libjpeg-turbo, and libyuv code bundled by libavif/libaom. This software is based
in part on the work of the Independent JPEG Group. Complete upstream notices
and the AOM patent license are supplied in `licenses/`.

Official upstreams:

- https://github.com/AOMediaCodec/libavif/releases/tag/v1.4.2
- https://aomedia.googlesource.com/aom/
- https://github.com/pnggroup/libpng
- https://github.com/madler/zlib
- https://github.com/libjpeg-turbo/libjpeg-turbo
