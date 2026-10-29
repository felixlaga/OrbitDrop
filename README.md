# OrbitDrop

A native macOS menu-bar utility recreated from the supplied recording: drag a file onto a glass radial menu to convert it, crop it, or add a background. It runs without a Dock icon.

[Download for Mac (Apple Silicon)](https://www.felixlaga.com/downloads/OrbitDrop-1.0.0-AppleSilicon.dmg)

## Install

1. Open `OrbitDrop.dmg` and drag **OrbitDrop** into **Applications**, or unzip `OrbitDrop-macOS-AppleSilicon.zip` and move the app there.
2. Open OrbitDrop. Its small circular icon appears in the menu bar.
3. Drag an image or PDF in Finder. Pause briefly while holding the mouse, then drop it on a wedge.

Built for Apple Silicon Macs with macOS 13 or later. This is a locally signed build, not an Apple-notarized release. If macOS blocks a downloaded copy, use the app-specific **Open Anyway** option in System Settings → Privacy & Security.

## Use

- **Convert:** Drag a PDF or image. Drop it on the desired format.
- **Tools:** Hold **⌥ Option** while dragging to show Compress, Metadata, Edit, Annotate, Add BG, Crop, and Redact. Release Option to return to formats.
- **Open without dragging:** Menu-bar icon → **Open File…**, or **⌃⌥Space**. Click the center to switch between formats and tools.
- **Move the wheel:** Drag its center pill. Editing panels move by their title bars.
- **Dismiss:** Press **Escape**. Dropping outside the wheel dismisses an active drag.
- **Originals:** Kept intact. Results are saved in the source folder with descriptive names and numeric suffixes to prevent overwriting.
- **Startup:** Enable **Open at Login** from the menu if wanted.
- **Quit:** Menu-bar icon → **Quit OrbitDrop**.

The app processes files locally; it does not upload documents or images.

## Reference scope

Recreated visible screens: four-way PDF conversion wheel, eight-way image conversion wheel, seven-way tools wheel, Crop Image editor, and Add BG editor. The reference demonstrates PDF → JPG → crop → background PNG.

The recording does not reveal its invocation shortcut, mode-switch gesture, or the internal screens for compression, metadata, adjustments, annotation, and redaction. OrbitDrop uses the gestures above and implements those additional tools in the same native glass style. It is an independent recreation, not the original app.

## Build

Requires Apple’s Command Line Tools. No package manager is needed to run the app.

```sh
bash build.sh
```

The application is written in Swift using AppKit, Core Graphics, ImageIO, PDFKit, Vision, and Core Image. The source includes tests and fixtures. See `VALIDATION.md` for the checks performed on this build and their limits.

macOS’s [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) setting provides the requested no-Dock behavior. Finder drags are discovered through the native [drag pasteboard](https://developer.apple.com/documentation/appkit/nspasteboard/name-swift.struct/drag), without a global keyboard recorder.
