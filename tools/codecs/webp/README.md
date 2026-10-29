# Portable WebP encoder

The distributable is `Resources/Codecs/webp/cwebp`, built from unmodified official
libwebp 1.6.0 and libpng 1.6.59 sources. It is arm64, targets macOS 13.0, and
contains libwebp, libwebpdemux, SharpYUV, and libpng statically. Its only direct
dynamic dependencies are Apple's `/usr/lib/libSystem.B.dylib` and
`/usr/lib/libz.1.dylib`. There are no Homebrew dependencies, loader search paths,
adjacent dylibs, installation steps, or environment-variable requirements.

Copy the entire `Resources/Codecs/webp` directory into the app's resources,
preserving the executable mode and license files. The binary is ad hoc signed;
the parent app's distribution signing remains a separate packaging step.

## Invocation from the repository root

Lossy PNG to WebP, with alpha retained:

```sh
Resources/Codecs/webp/cwebp -quiet -q 82 -m 6 -mt -metadata none input.png -o output.webp
```

Lossless, including RGB values behind completely transparent pixels:

```sh
Resources/Codecs/webp/cwebp -quiet -lossless -z 6 -exact -mt -metadata none input.png -o output.webp
```

Near-lossless:

```sh
Resources/Codecs/webp/cwebp -quiet -near_lossless 60 -m 6 -mt -metadata none input.png -o output.webp
```

Pass arguments separately when invoking with `Process`; use the resolved bundle
URL for the executable. PNG is the supported application interchange format.
JPEG, TIFF, GIF, WIC, OpenGL, and SDL integrations are disabled. Upstream's generic
help still mentions JPEG/TIFF, but those readers are absent from this build.
WebP/PNM readers, NEON, multithreading, and near-lossless encoding remain enabled.

## Rebuild and verify

```sh
tools/codecs/webp/build.sh
/usr/bin/python3 tools/codecs/webp/verify.py
```

The build requires Apple's Command Line Tools and uses only system shell tools,
Clang, make, the macOS SDK, and system zlib. CMake, Homebrew, autotools installation,
and a system-wide `make install` are unnecessary. Both release archives contain
generated configure scripts. The only `make install` stages libpng into a fresh
directory under this codec's `work/` tree. All explicit output, downloads,
temporary files, and staging paths remain within the owned WebP directories.

The script pins the source archive hashes, clears external include/library paths,
excludes Homebrew from `PATH`, disables pkg-config probing, sets `-arch arm64`
and `-mmacosx-version-min=13.0`, builds static libraries, dead-strips, and ad hoc
signs the final executable. It checks architecture, minimum OS, allowed runtime
dependencies, and signature before replacing the packaged executable atomically.
`WEBP_BUILD_JOBS` can override the parallel make count.

It also produces `tools/codecs/webp/bin/dwebp` as a local verification helper;
that decoder is not included in the app resources. Generated downloads, work,
decoder, and fixture files are ignored by the codec-local `.gitignore`.

`verify.py` uses only Python's standard library. It generates a 96x64 RGBA PNG,
checks RIFF length and `WEBP` magic, decodes all outputs using the freshly built
upstream decoder, checks dimensions and exact alpha, and compares every RGBA byte
for lossless cases. It invokes a standalone copied encoder beneath
`Moved App with spaces.app/Contents/Resources/Codecs/webp/` using a clean process
environment with no Homebrew in `PATH`, then checks the loader log for Homebrew
references. The executable and copied executable both pass strict signature
verification. Reports are `build-report.txt` and `verification-report.json`.
Two clean source builds in different directories produced identical encoder
bytes; `reproducibility-report.json` records that comparison.

The shared parent probe `tools/codecs/probes/output/input.png` was also encoded
using the lossy arguments above and decoded to PNG as 64x48 with alpha. Its
generated outputs are under `tools/codecs/webp/verification/shared-probe*`.

## Evidence boundary

The actual runtime checks ran on macOS 26.6.2 arm64. macOS 13 support is established
by compiling for that deployment target and auditing Mach-O metadata/dependencies;
this task did not run a macOS 13 host or VM. No parent engine, UI, main build
scripts, or application tests were modified.

The rejected `/opt/homebrew/bin/cwebp` was also 1.6.0, but had Mach-O minimum OS
26.0 and dependencies on Homebrew libpng, libjpeg, libtiff, and shared WebP/SharpYUV
libraries. It was not copied or changed.

See `Resources/Codecs/webp/PROVENANCE.md` for official source URLs, licenses,
compiler details, checksums, and packaged binary measurements.
