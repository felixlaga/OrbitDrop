# Encoders for app packaging

Copy this entire `Codecs` directory into `MyApp.app/Contents/Resources/`,
preserving executable bits and license/provenance files. Resolve each helper
relative to `Bundle.main.resourceURL`; pass absolute file paths as individual
Foundation `Process.arguments`, with no shell. Development/test executables
can resolve the same paths under the workspace's `Resources` directory.

| Format | Resource-relative executable | Runtime libraries |
|---|---|---|
| WebP | `Codecs/webp/cwebp` | Apple `libSystem.B.dylib`, `libz.1.dylib` |
| AVIF | `Codecs/avif/avifenc` | Apple `libSystem.B.dylib` |

Both are arm64 executables built with a macOS 13.0 deployment target. No
Homebrew files, third-party dylibs, installation, network access, or loader
environment variables are needed. Full-size PNG intermediates preserve alpha.

```text
cwebp -quiet -q 82 -m 6 -mt -metadata none /absolute/input.png -o /absolute/output.webp
avifenc -q 80 --qalpha 100 --speed 6 --jobs 2 --ignore-exif --ignore-xmp /absolute/input.png /absolute/output.avif
```

Both quality controls use 0–100. The WebP build supports PNG input; JPEG/TIFF
readers were intentionally omitted. The AVIF build also supports JPEG/Y4M.
Drain stdout and stderr or redirect them to files before synchronously waiting
for `Process` to exit. Check the exit status and output signature before
replacing the destination file. WebP begins `RIFF` and has `WEBP` at bytes 8–11;
AVIF is ISO BMFF with an `ftyp` box and the `avif` brand (typically bytes 4–11
read `ftypavif`).

The helpers are ad-hoc signed for local execution. For a Developer ID release,
sign these helpers with the application's identity before signing the enclosing
app. This task did not modify the app build, perform distribution signing, or
notarize anything. Detailed per-codec packaging notes and source licenses are in
the respective directories. This software is based in part on the work of the
Independent JPEG Group.

Actual runtime probes were on macOS 26.6.2 Apple Silicon. Binary metadata and
dependency audits establish the macOS 13 build target; a macOS 13 runtime was
not available. Current ImageIO advertises and successfully encodes `public.avif`
but does not advertise a WebP destination. Query available ImageIO destinations
at runtime rather than assuming that all supported OS versions encode AVIF.

Codec-only reproducible build scripts, signature/round-trip probes, and evidence
are in `tools/codecs` in the source workspace. These source/build tools are not
needed in the shipped app; package only this resource directory.
