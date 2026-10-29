#!/usr/bin/python3
"""Portable encoder smoke test; Python standard library only. Run build.sh first."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ENCODER = ROOT / "Resources/Codecs/webp/cwebp"
DECODER = HERE / "bin/dwebp"
OUT = HERE / "verification"
OUT.mkdir(exist_ok=True)
RELOCATED = OUT / "Moved App with spaces.app/Contents/Resources/Codecs/webp/cwebp"
RELOCATED.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(ENCODER, RELOCATED)
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(OUT)}


def run(argv, **kwargs):
    return subprocess.run([str(arg) for arg in argv], env=ENV, check=True,
                          capture_output=True, **kwargs)


def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload +
            struct.pack(">I", zlib.crc32(kind + payload)))


width, height = 96, 64
rgba = bytes(channel for y in range(height) for x in range(width)
             for channel in ((x * 7 + y * 3) % 256, (x * 2 + y * 11) % 256,
                             (x * 13 + y * 5) % 256,
                             [0, 64, 128, 192, 255][(x // 12 + y // 8) % 5]))
rows = b"".join(b"\0" + rgba[y * width * 4:(y + 1) * width * 4]
                for y in range(height))
source = OUT / "input with alpha.png"
source.write_bytes(b"\x89PNG\r\n\x1a\n" +
                   chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) +
                   chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))

report = {
    "host": run(["/usr/bin/sw_vers", "-productVersion"], text=True).stdout.strip(),
    "version": run([ENCODER, "-version"], text=True).stdout.strip(),
    "binary": str(ENCODER),
    "sha256": hashlib.sha256(ENCODER.read_bytes()).hexdigest(),
    "size_bytes": ENCODER.stat().st_size,
    "architectures": run(["/usr/bin/lipo", "-archs", ENCODER], text=True).stdout.strip(),
    "runtime_dependencies": run(["/usr/bin/otool", "-L", ENCODER], text=True).stdout,
    "environment": ENV,
    "source_dimensions": [width, height],
    "cases": [],
}
assert report["architectures"] == "arm64"
load_commands = run(["/usr/bin/otool", "-l", ENCODER], text=True).stdout
assert "minos 13.0\n" in load_commands
report["minimum_macos"] = "13.0"
dependencies = [line.split()[0] for line in report["runtime_dependencies"].splitlines()[1:]]
assert set(dependencies) == {"/usr/lib/libz.1.dylib", "/usr/lib/libSystem.B.dylib"}
assert "LC_RPATH" not in load_commands
run(["/usr/bin/codesign", "--verify", "--strict", ENCODER])
run(["/usr/bin/codesign", "--verify", "--strict", RELOCATED])

for name, encoder, options, exact in [
    ("lossless-bundled", ENCODER, ["-lossless", "-z", "6", "-exact"], True),
    ("lossless-relocated", RELOCATED, ["-lossless", "-z", "6", "-exact"], True),
    ("lossy-relocated", RELOCATED, ["-q", "82", "-m", "6"], False),
    ("near-lossless-relocated", RELOCATED, ["-near_lossless", "60", "-m", "6"], False),
]:
    encoded = OUT / (name + ".webp")
    decoded = OUT / (name + ".pam")
    encode_argv = [encoder, "-quiet", *options, "-mt", "-metadata", "none", source, "-o", encoded]
    run(encode_argv)
    data = encoded.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    assert struct.unpack("<I", data[4:8])[0] + 8 == len(data)
    decode_argv = [DECODER, "-quiet", encoded, "-pam", "-o", decoded]
    run(decode_argv)
    header, pixels = decoded.read_bytes().split(b"ENDHDR\n", 1)
    assert header.startswith(b"P7\n")
    for field in [f"WIDTH {width}", f"HEIGHT {height}", "DEPTH 4", "MAXVAL 255"]:
        assert field.encode() in header
    assert len(pixels) == len(rgba)
    assert pixels[3::4] == rgba[3::4], "alpha plane changed"
    if exact:
        assert pixels == rgba, "lossless RGBA round trip changed pixels"
    report["cases"].append({
        "name": name, "encode_argv": [str(arg) for arg in encode_argv],
        "decode_argv": [str(arg) for arg in decode_argv],
        "webp_signature_hex": data[:12].hex(), "size_bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "decode": "96x64 RGBA; alpha exact", "all_pixels_exact": pixels == rgba,
    })

dynamic = subprocess.run([str(RELOCATED), "-version"],
                         env={**ENV, "DYLD_PRINT_LIBRARIES": "1"},
                         capture_output=True, text=True, check=True)
assert "/opt/homebrew" not in dynamic.stderr
(OUT / "relocated-dyld.log").write_text(dynamic.stderr)
report["relocated_dyld_log_file"] = str(OUT / "relocated-dyld.log")
report["relocated_dyld_homebrew_references"] = False
report["result"] = "PASS"
(HERE / "verification-report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({key: report[key] for key in ["result", "version", "minimum_macos",
                 "architectures", "size_bytes", "sha256"]}, indent=2))
