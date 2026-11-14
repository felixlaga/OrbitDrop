# Build validation

## 1.2.0: video conversion and the 2-second hold

Verified in CI on a GitHub `macos-26` runner (Apple Silicon VM), see `.github/workflows/macos.yml`. No step ran on a local Mac.

### Passed in CI

- `bash test.sh`: every earlier suite still passes, including the 97 media assertions and the editor checks.
- `HoldGestureTests`: a still press asks Finder at exactly 2 s and only once; letting go early never opens; a press that moved without a drag never asks; a drag opens once it pauses for 2 s; a drag that keeps moving never opens; an open wheel never jumps to a later pause.
- `RadialMenuTests`: videos get MP4, MOV, GIF and M4A with working hit targets; videos have no tools wheel; images and videos never share a wheel.
- `VideoEngineTests` (35 assertions, on clips the test makes with AVFoundation):
  - H.264 + AAC to MP4 copies both tracks and keeps the length. ProRes to MP4 re-encodes to H.264.
  - MOV keeps picture and sound and never overwrites the original (`Clip 2.mov`).
  - GIF: about 10 frames a second, small clips keep their size, 1280×720 becomes 640×360, a 32 s clip is refused.
  - M4A is AAC sound only. A silent clip is refused.
  - Cancelling before an export and halfway through a GIF saves nothing. No staging folders are left. The original is unchanged.
- `tools/verify-package.py`: the packaged app converts a clip named `Screen Recording 日本.mov` to MP4, MOV, GIF and M4A from a relocated bundle.

### Not verified

- **The live hold in Finder.** CI can't press a mouse in Finder. The timing rule is tested, but the Finder selection read, the Automation prompt and the hand-off from hold to drag were not run on a real desktop.
- **Weak spot by design.** With a file already selected, a still 2 s press on a Finder toolbar or sidebar also opens the wheel for that file. Seeing exactly what is under the pointer would need Accessibility permission.
- HDR and Dolby Vision iPhone clips were not tested. AVFoundation converts them when re-encoding to H.264, but colour accuracy was not checked.
- Copy-protected M4V files are refused with a message, but no such file was tested.
- WebM, MKV and AVI are not read. AVFoundation can't open them.
- ImageIO labels animated GIFs `GIF87a`. OrbitDrop relabels them `GIF89a`, which the frame delays and looping need.

## 1.1.0

Verified on an Apple Silicon Mac running macOS 26.6.2. Deployment target is macOS 13; an older macOS runtime and Intel Mac were not available for testing.

## Passed

- The complete native application compiles in Swift 5 mode.
- **UI redo, measured from the recording.** Frames were extracted at 4–30 fps and measured in points, using Finder's 12 pt desktop labels as a ruler. Wheel: 238 pt across, wedges from 47 to 112 pt radius, 6 pt glass gaps, 68 × 34 pt centre pill. Crop window 370 × 560 pt, Add BG window 418 × 618 pt, progress card 312 × 93 pt.
- Off-screen renders of the 4-, 8- and 7-wedge wheels were composited over the video's own wallpaper at the same position and compared side by side with the matching frames, including hover states and the centre label. Editor snapshots were compared the same way.
- Wheel tests cover action order, every hit target at the new size, centre/outside exclusion, busy and empty-input guards, and pasteboard decoding.
- 97 media integration assertions pass (unchanged engine): JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF, DOCX, TXT, compression and metadata.
- Off-screen editor tests: crop corner drag, selection move, five fixed ratios, free crop, Apply export sizes, and Add BG exports at Auto, 1:1, 16:9 and 4:5. Add BG defaults match the recording: Padding 160 px, Corners 24 px, Shadow 24 px, Auto.
- The packaged bundle passes the relocated-path CLI check for all formats.

## Evidence boundaries

The first version's radial menu was inspected in the live native app. The user then requested that testing stop covering their laptop, so the test app was stopped and all remaining verification ran off-screen. The app is left closed. A complete live Finder drag-and-drop end-to-end session was not performed. Native drag callbacks and the polling logic received two independent code-review rounds; reported defects were fixed. Menu-bar Open File is also available as a direct entry point.

Off-screen snapshots verify native control layout and rendering, but cannot reproduce behind-window desktop vibrancy. The recording is a phone capture of a desktop demo; original source code, exact physical window dimensions, and hidden tool screens were not supplied. Pixel-identical parity with the original app is therefore not claimed.

The bundle is ad-hoc signed for local use. It is not Developer ID signed or Apple notarized. Login-item behavior and Gatekeeper behavior on a separately downloaded Mac were not tested.

## Functional scope

- Crop/background/adjustment/annotation/redaction operate on a single raster image. For a PDF input, editing uses its first page. PDF-to-JPG/PNG conversion exports all pages.
- Crop preserves a supported source image encoding; other visual edits export PNG.
- PDF-to-DOCX extracts text and uses OCR for scanned pages. It does not reconstruct the original Word layout. Image-to-DOCX embeds the image.
- Metadata removal supports image metadata; it is not a PDF sanitization tool. Compression only saves a new file when it is smaller; some already-compressed images cannot be reduced further. PDF compression requires macOS 13.4 or later.
- Animation and multi-frame editing are not implemented. Conversion, compression, and metadata removal explicitly reject multi-frame images to avoid silently losing frames.

## Reproduce

```sh
bash test.sh
bash build.sh
python3 tools/verify-package.py
bash package.sh
```

Test reports and native panel PNGs are retained under `build/test-report.txt`, `build/engine-final-report.txt`, `build/editor-qa/`, and `build/package-checks/report.json` in the original workspace. These generated outputs are not required to run the app.
