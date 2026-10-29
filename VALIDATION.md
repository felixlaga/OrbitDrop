# Build validation

Verified on an Apple Silicon Mac running macOS 26.6.2. Deployment target is macOS 13; an older macOS runtime and Intel Mac were not available for testing.

## Passed

- The complete native application compiles in Swift 5 mode.
- All reference wheel action orders and hit targets match the extracted frames. Tests cover center/outside exclusion, busy and empty-input guards, file URL decoding, and stale hover reset when changing wheel sizes.
- 97 media integration assertions: real output types and dimensions for JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP; atomic non-overwriting writes, concurrent filenames and symlinks; EXIF orientation; metadata removal; all PDF pages at 300 DPI, page rotation, PDF content scaling and annotations, native text and mixed-content OCR; valid DOCX ZIP/XML/image relationships and Unicode; actual JPEG size reduction; malformed input, page-truncation rejection, and concurrent rollback behavior.
- Off-screen native editor tests dispatch events directly to hidden controls. Crop corner dragging, selection movement, five fixed aspect ratios, free cropping, actual Apply callbacks, JPEG preservation, and exact 640×480 / 640×360 exports pass.
- Actual Add BG Save callbacks export PNG at the expected Auto, 1:1, 16:9, and 4:5 dimensions. Padding/corners/shadow defaults match the recording. Transparent image pixels remain transparent over the background instead of gaining an opaque shadow plate.
- All seven editor panels were rendered off-screen and visually inspected for layout. Crop and Add BG use reference-sized source images and the demonstrated settings.
- A relocated app bundle under a path containing spaces and Japanese characters was exercised through its no-window CLI with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. All ten conversion formats passed, the original remained unchanged, and a second conversion selected a new filename.
- The application bundle passes local code-signature verification. WebP and AVIF helpers are bundled with their licenses and require only Apple system libraries.

## Evidence boundaries

The radial menu was initially inspected in the live native app. The user then requested that testing stop covering their laptop, so the test app was stopped and all remaining verification ran off-screen. The app is left closed. A complete live Finder drag-and-drop end-to-end session was not performed. Native drag callbacks and the polling logic received two independent code-review rounds; reported defects were fixed. Menu-bar Open File is also available as a direct entry point.

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
