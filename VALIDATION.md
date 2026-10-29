# Build validation

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
