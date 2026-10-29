import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Owns editor windows independently of the radial launcher.
public final class EditorCoordinator: NSObject {
    private var editors: [UUID: ODEditorController] = [:]
    public override init() { super.init() }
    public var openWindows: [NSWindow] { editors.values.compactMap(\.window) }

    public func open(action: String, url: URL, at point: NSPoint? = nil, onSaved: @escaping (URL) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.open(action: action, url: url, at: point, onSaved: onSaved) }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        do {
            let window = try makeOffscreenWindow(action: action, url: url, onSaved: onSaved)
            (window.windowController as? ODEditorController)?.presentsErrors = true
            // The editor opens where the wheel was, kept fully on screen.
            let anchor = point ?? NSEvent.mouseLocation
            let screen = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: max(screen.minX+8, min(anchor.x-size.width/2, screen.maxX-size.width-8)),
                                          y: max(screen.minY+8, min(anchor.y-size.height/2, screen.maxY-size.height-8))))
            window.alphaValue = 0
            if let layer = window.contentView?.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.position = CGPoint(x: size.width/2, y: size.height/2)
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.92; grow.toValue = 1; grow.duration = 0.2
                grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                layer.add(grow, forKey: "grow")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.16; window.animator().alphaValue = 1 }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Off-screen QA entry point. Does not show, order, or activate any window.
    /// The caller can inspect accessibility identifiers or cacheDisplay the content view.
    public func makeOffscreenWindow(action: String, url: URL, onSaved: @escaping (URL) -> Void = { _ in }) throws -> NSWindow {
        precondition(Thread.isMainThread, "Create AppKit editors on the main thread")
        let kind = action.lowercased()
        let controller: ODEditorController
        switch kind {
        case "crop": controller = ODCropController(url: url, image: try MediaEngine.loadImage(url))
        case "background", "add bg", "addbg": controller = ODBackgroundController(url: url, image: try MediaEngine.loadImage(url))
        case "annotate", "redact": controller = ODMarkupController(url: url, image: try MediaEngine.loadImage(url), redaction: kind == "redact")
        case "edit": controller = ODAdjustmentController(url: url, image: try MediaEngine.loadImage(url))
        case "compress": controller = ODCompressionController(url: url, image: try? MediaEngine.loadImage(url))
        case "metadata": controller = ODMetadataController(url: url, entries: try MediaEngine.metadata(url))
        default: throw ODEditorError.message("The “\(action)” editor is not available.")
        }
        let id = UUID()
        controller.onSaved = onSaved
        controller.onClosed = { [weak self] in self?.editors.removeValue(forKey: id) }
        editors[id] = controller
        return controller.window!
    }
}

enum ODEditorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private var odOrange: NSColor { orbitAccent }

class ODFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ODEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

private final class ODTitleBar: ODFlippedView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Small rounded-rectangle buttons from the reference: grey “Reset”, orange primary action.
private final class ODActionButton: NSButton {
    var handler: (() -> Void)?
    private let primary: Bool
    init(_ title: String, frame: NSRect, identifier: String, primary: Bool = false, handler: (() -> Void)? = nil) {
        self.primary = primary
        super.init(frame: frame)
        self.title = title
        self.handler = handler
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityIdentifier(identifier)
        font = .systemFont(ofSize: 11, weight: primary ? .medium : .regular)
        isBordered = false
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        if primary { (isHighlighted ? odOrange.blended(withFraction: 0.18, of: .black)! : odOrange).withAlphaComponent(isEnabled ? 1 : 0.5).setFill() }
        else { NSColor.black.withAlphaComponent(isHighlighted ? 0.13 : 0.075).setFill() }
        shape.fill()
        if let image, title.isEmpty {
            let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.labelColor.withAlphaComponent(0.7)]))) ?? image
            let s = tinted.size
            tinted.draw(in: NSRect(x: bounds.midX-s.width/2, y: bounds.midY-s.height/2, width: s.width, height: s.height))
            return
        }
        let text = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 11), .foregroundColor: primary ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.72)])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX-size.width/2, y: bounds.midY-size.height/2))
    }
}

@discardableResult
private func odLabel(_ text: String, _ frame: NSRect, in parent: NSView, size: CGFloat = 10.5, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.frame = frame
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? NSColor.labelColor.withAlphaComponent(0.58) : .labelColor
    label.lineBreakMode = .byTruncatingTail
    parent.addSubview(label)
    return label
}

/// A label vertically centred on `centerY` (flipped coordinates).
@discardableResult
private func odRowLabel(_ text: String, x: CGFloat, centerY: CGFloat, width: CGFloat = 80, in parent: NSView) -> NSTextField {
    odLabel(text, CGRect(x: x, y: centerY-7.5, width: width, height: 15), in: parent, secondary: true)
}

private func odIdentifier(_ view: NSView, _ id: String) {
    view.identifier = NSUserInterfaceItemIdentifier(id)
    view.setAccessibilityIdentifier(id)
}

private func odFit(_ image: CGSize, in rect: CGRect) -> CGRect {
    let scale = min(rect.width / image.width, rect.height / image.height)
    return CGRect(x: rect.midX - image.width * scale / 2, y: rect.midY - image.height * scale / 2, width: image.width * scale, height: image.height * scale)
}

private func odDraw(_ image: CGImage, in rect: CGRect) {
    NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

/// Editor windows: a glass card with a 38 pt title bar and a 49 pt action bar.
class ODEditorController: NSWindowController, NSWindowDelegate {
    static let titleBarHeight: CGFloat = 38
    static let actionBarHeight: CGFloat = 49
    let sourceURL: URL
    let surface: ODFlippedView
    var onSaved: ((URL) -> Void)?
    var onClosed: (() -> Void)?
    var presentsErrors = false
    private(set) var lastError: Error?
    private(set) var saveButton: NSButton!
    private var status: NSTextField!
    private var isSaving = false
    var contentWidth: CGFloat { surface.bounds.width }
    var actionBarTop: CGFloat { surface.bounds.height - Self.actionBarHeight }

    init(url: URL, title: String, saveTitle: String, action: String, size: CGSize = CGSize(width: 420, height: 630)) {
        sourceURL = url
        surface = ODFlippedView(frame: CGRect(origin: .zero, size: size))
        let panel = ODEditorPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = title
        panel.setAccessibilityIdentifier("editor.\(action).window")
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)
        panel.delegate = self
        let radius: CGFloat = 20
        let root = NSView(frame: surface.frame)
        root.wantsLayer = true
        // Clear glass plus a light wash, so the wallpaper's colour shows through as in the recording.
        root.addSubview(makeGlassBackdrop(frame: root.bounds, cornerRadius: radius, clear: true))
        let tint = NSView(frame: root.bounds); tint.wantsLayer = true
        tint.layer?.cornerRadius = radius
        tint.layer?.backgroundColor = (usesSystemGlass ? NSColor.white.withAlphaComponent(0.2) : NSColor(calibratedRed: 1, green: 0.93, blue: 0.86, alpha: 0.16)).cgColor
        root.addSubview(tint)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = radius
        surface.layer?.borderWidth = 0.5
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.38).cgColor
        root.addSubview(surface)
        panel.contentView = root
        let titleBar = ODTitleBar(frame: CGRect(x: 0, y: 0, width: size.width, height: Self.titleBarHeight))
        surface.addSubview(titleBar)
        let heading = odLabel(title, CGRect(x: 50, y: 10.5, width: size.width-100, height: 18), in: titleBar, size: 14, weight: .semibold)
        heading.alignment = .center
        heading.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        let close = CloseCircleButton(frame: CGRect(x: 12, y: 8, width: 22, height: 22), identifier: "editor.\(action).close", label: "Close \(title)")
        close.handler = { [weak self] in self?.close() }
        titleBar.addSubview(close)
        separator(y: Self.titleBarHeight)
        separator(y: actionBarTop)
        let buttonY = size.height - Self.actionBarHeight/2 - 10
        let reset = ODActionButton("Reset", frame: CGRect(x: 14, y: buttonY, width: 46, height: 20), identifier: "editor.\(action).reset") { [weak self] in self?.resetEditor() }
        surface.addSubview(reset)
        let width = ceil(NSAttributedString(string: saveTitle, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).size().width) + 20
        let save = ODActionButton(saveTitle, frame: CGRect(x: size.width - 14 - width, y: buttonY, width: width, height: 20), identifier: "editor.\(action).save", primary: true) { [weak self] in self?.saveEditor() }
        save.keyEquivalent = "\r"
        saveButton = save
        surface.addSubview(save)
        status = odLabel("", CGRect(x: 70, y: buttonY+3, width: max(40, size.width - width - 98), height: 15), in: surface, size: 10, secondary: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func separator(y: CGFloat) {
        let line = NSView(frame: CGRect(x: 0, y: y, width: surface.bounds.width, height: 0.5))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.09).cgColor
        surface.addSubview(line)
    }
    func resetEditor() {}
    func saveEditor() {}
    func windowWillClose(_ notification: Notification) { onClosed?() }
    func report(_ error: Error) {
        lastError = error
        guard presentsErrors else { return }
        guard let window = window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
    func saveImage(_ image: CGImage?, suffix: String, format: String = "png") {
        guard let image = image else { report(ODEditorError.message("The image could not be rendered.")); return }
        let destination = MediaEngine.uniqueSibling(for: sourceURL, suffix: suffix, ext: format)
        performSave {
            try MediaEngine.writeImage(image, format: format, to: destination, quality: 0.9)
            return destination
        }
    }
    func performSave(_ work: @escaping () throws -> URL) {
        guard !isSaving else { return }
        isSaving = true
        saveButton.isEnabled = false
        status.stringValue = "Saving…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [self] in
                isSaving = false
                saveButton.isEnabled = true
                status.stringValue = ""
                switch result {
                case .success(let url): onSaved?(url); close()
                case .failure(let error): report(error)
                }
            }
        }
    }
}

final class ODPreviewView: ODFlippedView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var inset: CGFloat = 12
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.035).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        if let image = image { odDraw(image, in: odFit(CGSize(width: image.width, height: image.height), in: bounds.insetBy(dx: inset, dy: inset))) }
    }
}

/// Segmented control drawn as in the reference: a light track, an orange selected
/// segment, and thin dividers between unselected neighbours. It stays orange when
/// the window is inactive, as in the recording.
private final class ODRatioControl: NSSegmentedControl {
    var handler: ((Int) -> Void)?
    override var selectedSegment: Int { didSet { needsDisplay = true } }
    init(labels: [String], frame: CGRect, id: String, handler: @escaping (Int) -> Void) {
        super.init(frame: frame)
        segmentCount = labels.count
        for (index, label) in labels.enumerated() { setLabel(label, forSegment: index); setWidth(frame.width / CGFloat(labels.count), forSegment: index) }
        trackingMode = .selectOne
        controlSize = .small
        font = .systemFont(ofSize: 11)
        selectedSegment = 0
        self.handler = handler
        target = self
        action = #selector(changed)
        odIdentifier(self, id)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { handler?(selectedSegment) }
    private var segmentWidth: CGFloat { bounds.width / CGFloat(max(1, segmentCount)) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.065).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        for index in 0..<segmentCount {
            let part = CGRect(x: CGFloat(index)*segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
            if index == selectedSegment {
                orbitAccent.setFill()
                NSBezierPath(roundedRect: part, xRadius: 5, yRadius: 5).fill()
            } else if index > 0, index-1 != selectedSegment {
                NSColor.black.withAlphaComponent(0.18).setFill()
                NSRect(x: part.minX-0.5, y: bounds.midY-5, width: 1, height: 10).fill()
            }
            let selected = index == selectedSegment
            let text = NSAttributedString(string: label(forSegment: index) ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .medium : .regular),
                .foregroundColor: selected ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.72)])
            let size = text.size()
            text.draw(at: CGPoint(x: part.midX-size.width/2, y: part.midY-size.height/2))
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = max(0, min(segmentCount-1, Int(point.x / segmentWidth)))
        guard index != selectedSegment else { return }
        selectedSegment = index
        handler?(index)
    }
}

/// Slider drawn as in the reference: thin track, orange fill, white capsule knob.
private final class ODSliderCell: NSSliderCell {
    static let knobSize = CGSize(width: 18, height: 12)
    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let fraction = CGFloat((doubleValue-minValue)/max(0.0001, maxValue-minValue))
        let k = Self.knobSize
        let x = bar.minX + (bar.width-k.width)*fraction
        return NSRect(x: x, y: bar.midY-k.height/2, width: k.width, height: k.height)
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = CGRect(x: rect.minX, y: rect.midY-1.5, width: rect.width, height: 3)
        NSColor.white.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let knob = knobRect(flipped: flipped)
        let progress = CGRect(x: track.minX, y: track.minY, width: max(0, knob.midX-track.minX), height: track.height)
        orbitAccent.setFill()
        NSBezierPath(roundedRect: progress, xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let knob = knobRect.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: knob, xRadius: knob.height/2, yRadius: knob.height/2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowOffset = CGSize(width: 0, height: -0.5); shadow.shadowBlurRadius = 2; shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.set()
        NSColor(calibratedWhite: 0.985, alpha: 1).setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke(); shape.lineWidth = 0.5; shape.stroke()
    }
}

/// Source-pixel selection with top-left coordinates, matching CGImage cropping.
final class ODCropCanvas: ODFlippedView {
    let image: CGImage
    var selection: CGRect { didSet { needsDisplay = true; onChange?(selection) } }
    var aspectRatio: CGFloat? = nil
    var onChange: ((CGRect) -> Void)?
    private var startRect = CGRect.zero
    private var startPoint = CGPoint.zero
    private var dragHandle = -1
    private var sourceBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    private var imageRect: CGRect { odFit(sourceBounds.size, in: bounds.insetBy(dx: 10, dy: 10)) }
    private var displaySelection: CGRect {
        let r = imageRect, scale = r.width / CGFloat(image.width)
        return CGRect(x: r.minX + selection.minX * scale, y: r.minY + selection.minY * scale, width: selection.width * scale, height: selection.height * scale)
    }
    init(image: CGImage) {
        self.image = image
        selection = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        super.init(frame: .zero)
        odIdentifier(self, "editor.crop.canvas")
        setAccessibilityLabel("Crop selection. Drag edges or corners to resize; drag inside to move.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x:r.minX,y:r.minY), CGPoint(x:r.midX,y:r.minY), CGPoint(x:r.maxX,y:r.minY), CGPoint(x:r.maxX,y:r.midY), CGPoint(x:r.maxX,y:r.maxY), CGPoint(x:r.midX,y:r.maxY), CGPoint(x:r.minX,y:r.maxY), CGPoint(x:r.minX,y:r.midY)]
    }
    override func draw(_ dirtyRect: NSRect) {
        let full = imageRect, selected = displaySelection
        odDraw(image, in: full)
        NSColor.black.withAlphaComponent(0.55).setFill()
        let mask = NSBezierPath(rect: full)
        mask.appendRect(selected)
        mask.windingRule = .evenOdd
        mask.fill()
        odOrange.setStroke()
        let outline = NSBezierPath(rect: selected)
        outline.lineWidth = 1.5
        outline.stroke()
        if dragHandle != -1 {
            NSColor.white.withAlphaComponent(0.42).setStroke()
            let grid = NSBezierPath()
            for fraction in [CGFloat(1.0/3), CGFloat(2.0/3)] {
                grid.move(to: CGPoint(x: selected.minX + selected.width * fraction, y: selected.minY)); grid.line(to: CGPoint(x: selected.minX + selected.width * fraction, y: selected.maxY))
                grid.move(to: CGPoint(x: selected.minX, y: selected.minY + selected.height * fraction)); grid.line(to: CGPoint(x: selected.maxX, y: selected.minY + selected.height * fraction))
            }
            grid.lineWidth = 0.5
            grid.stroke()
        }
        odOrange.setFill()
        for (index, p) in handles(selected).enumerated() {
            let size = index % 2 == 0 ? CGSize(width: 10, height: 10) : ((index == 1 || index == 5) ? CGSize(width: 20, height: 5) : CGSize(width: 5, height: 20))
            let radius: CGFloat = index % 2 == 0 ? 2 : 2.5
            NSBezierPath(roundedRect: CGRect(x: p.x-size.width/2, y:p.y-size.height/2, width:size.width,height:size.height), xRadius:radius,yRadius:radius).fill()
        }
    }
    private func sourcePoint(_ point: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: min(CGFloat(image.width), max(0, (point.x-r.minX) * CGFloat(image.width)/r.width)), y: min(CGFloat(image.height), max(0, (point.y-r.minY) * CGFloat(image.height)/r.height)))
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startRect = selection
        startPoint = sourcePoint(p)
        dragHandle = handles(displaySelection).firstIndex(where: { hypot($0.x-p.x, $0.y-p.y) <= 11 }) ?? (displaySelection.contains(p) ? 8 : 9)
        if dragHandle == 9 { startRect = CGRect(origin: startPoint, size: .zero) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let p = sourcePoint(convert(event.locationInWindow, from: nil))
        if dragHandle == 8 {
            var r = startRect
            r.origin.x = min(sourceBounds.width-r.width, max(0, startRect.minX+p.x-startPoint.x))
            r.origin.y = min(sourceBounds.height-r.height, max(0, startRect.minY+p.y-startPoint.y))
            selection = r
            return
        }
        guard dragHandle >= 0 else { return }
        if dragHandle == 9 {
            let anchor = startPoint
            let sx: CGFloat = p.x >= anchor.x ? 1 : -1, sy: CGFloat = p.y >= anchor.y ? 1 : -1
            selection = cornerRect(anchor: anchor, width: abs(p.x-anchor.x), height: abs(p.y-anchor.y), sx: sx, sy: sy)
            return
        }
        let left = [0,6,7].contains(dragHandle), right = [2,3,4].contains(dragHandle)
        let top = [0,1,2].contains(dragHandle), bottom = [4,5,6].contains(dragHandle)
        if (left || right) && (top || bottom) {
            let anchor = CGPoint(x: left ? startRect.maxX : startRect.minX, y: top ? startRect.maxY : startRect.minY)
            selection = cornerRect(anchor: anchor, width: max(1, left ? anchor.x-p.x : p.x-anchor.x), height: max(1, top ? anchor.y-p.y : p.y-anchor.y), sx: left ? -1 : 1, sy: top ? -1 : 1)
        } else {
            var r = startRect
            if left { r.origin.x = min(p.x,r.maxX-1); r.size.width = startRect.maxX-r.minX }
            if right { r.size.width = max(1,p.x-r.minX) }
            if top { r.origin.y = min(p.y,r.maxY-1); r.size.height = startRect.maxY-r.minY }
            if bottom { r.size.height = max(1,p.y-r.minY) }
            if let ratio = aspectRatio {
                if left || right { r.size.height = r.width/ratio; r.origin.y = startRect.midY-r.height/2 }
                else { r.size.width = r.height*ratio; r.origin.x = startRect.midX-r.width/2 }
            }
            selection = bounded(r)
        }
    }
    override func mouseUp(with event: NSEvent) { dragHandle = -1; selection = bounded(selection); needsDisplay = true }
    private func cornerRect(anchor: CGPoint, width: CGFloat, height: CGFloat, sx: CGFloat, sy: CGFloat) -> CGRect {
        var w = max(1,width), h = max(1,height)
        if let ratio = aspectRatio { if w/h > ratio { h = w/ratio } else { w = h*ratio } }
        let maxW = sx > 0 ? sourceBounds.width-anchor.x : anchor.x
        let maxH = sy > 0 ? sourceBounds.height-anchor.y : anchor.y
        let scale = min(1, maxW/w, maxH/h)
        w *= scale; h *= scale
        return CGRect(x: sx > 0 ? anchor.x : anchor.x-w, y: sy > 0 ? anchor.y : anchor.y-h, width:max(1,w), height:max(1,h))
    }
    private func bounded(_ rect: CGRect) -> CGRect {
        var r = rect
        if aspectRatio == nil {
            r.size.width = min(sourceBounds.width,max(1,r.width))
            r.size.height = min(sourceBounds.height,max(1,r.height))
        } else {
            let scale = min(1, sourceBounds.width/max(1,r.width), sourceBounds.height/max(1,r.height))
            r.size.width = max(1,r.width*scale); r.size.height = max(1,r.height*scale)
        }
        r.origin.x = max(0,min(r.origin.x,sourceBounds.width-r.width))
        r.origin.y = max(0,min(r.origin.y,sourceBounds.height-r.height))
        return r
    }
    func setRatio(_ ratio: CGFloat?) {
        aspectRatio = ratio
        guard let ratio = ratio else { return }
        // As in the reference, a preset keeps the selection's top-left corner and width,
        // then fits the new height inside the image.
        var size = CGSize(width: selection.width, height: selection.width/ratio)
        let fit = min(1, sourceBounds.width/size.width, sourceBounds.height/size.height)
        size = CGSize(width: size.width*fit, height: size.height*fit)
        selection = bounded(CGRect(origin: selection.origin, size: size))
    }
    func setSize(width: CGFloat, height: CGFloat, changingWidth: Bool) {
        guard width.isFinite, height.isFinite else { return }
        var w = max(1,width), h = max(1,height)
        if let ratio = aspectRatio { if changingWidth { h = w/ratio } else { w = h*ratio } }
        selection = bounded(CGRect(origin: selection.origin, size: CGSize(width: w,height: h)))
    }
    func reset() { aspectRatio = nil; selection = sourceBounds }
    func croppedImage() -> CGImage? {
        let r = CGRect(x: selection.minX.rounded(), y: selection.minY.rounded(), width: max(1,selection.width.rounded()), height: max(1,selection.height.rounded())).intersection(sourceBounds)
        return image.cropping(to: r)
    }
}

private final class ODCropController: ODEditorController, NSTextFieldDelegate {
    let canvas: ODCropCanvas
    private var ratio: ODRatioControl!
    private let widthField = NSTextField(), heightField = NSTextField()
    init(url: URL, image: CGImage) {
        canvas = ODCropCanvas(image: image)
        super.init(url: url, title: "Crop Image", saveTitle: "Apply", action: "crop", size: CGSize(width: 370, height: 560))
        canvas.frame = CGRect(x: 16, y: 47, width: 338, height: 382)
        surface.addSubview(canvas)
        odRowLabel("Aspect ratio", x: 15, centerY: 455, in: surface)
        ratio = ODRatioControl(labels: ["Free","1:1","16:9","9:16","4:3","3:4"], frame:CGRect(x:121,y:445,width:233,height:20), id:"editor.crop.ratio") { [weak self] index in
            let ratios: [CGFloat?] = [nil,1,16.0/9,9.0/16,4.0/3,3.0/4]
            self?.canvas.setRatio(ratios[index])
        }
        surface.addSubview(ratio)
        odRowLabel("W", x: 16, centerY: 485, width: 12, in: surface)
        odRowLabel("H", x: 96, centerY: 485, width: 12, in: surface)
        odRowLabel("px", x: 174, centerY: 485, width: 24, in: surface)
        for (field, x, id) in [(widthField,CGFloat(30),"editor.crop.width"),(heightField,CGFloat(108),"editor.crop.height")] {
            field.frame = CGRect(x:x,y:475.5,width:59,height:19)
            field.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
            field.controlSize = .small
            field.bezelStyle = .roundedBezel
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.allowsFloats = false
            formatter.minimum = 1
            field.formatter = formatter
            field.delegate = self
            field.target = self
            field.action = #selector(sizeChanged(_:))
            odIdentifier(field,id)
            surface.addSubview(field)
        }
        canvas.onChange = { [weak self] rect in self?.widthField.stringValue = String(Int(rect.width.rounded())); self?.heightField.stringValue = String(Int(rect.height.rounded())) }
        canvas.reset()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func sizeChanged(_ sender: NSTextField) { canvas.setSize(width: CGFloat(widthField.doubleValue), height: CGFloat(heightField.doubleValue), changingWidth: sender === widthField) }
    func controlTextDidEndEditing(_ obj: Notification) { if let field = obj.object as? NSTextField { sizeChanged(field) } }
    override func resetEditor() { canvas.reset(); ratio.selectedSegment = 0 }
    override func saveEditor() {
        window?.makeFirstResponder(nil)
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let canonicalExtension = ["jpeg":"jpg","heif":"heic","tif":"tiff"][sourceExtension] ?? sourceExtension
        let sourceType = UTType(filenameExtension:canonicalExtension)
        let preserve = ["jpg","jpeg","png","heic","heif","tif","tiff","bmp","avif","webp"].contains(sourceExtension)
            && sourceType.map { supported.contains($0.identifier) } == true
        saveImage(canvas.croppedImage(), suffix:" Cropped", format:preserve ? sourceExtension : "png")
    }
}

struct ODBackgroundStyle {
    /// A soft colour blob: centre as fractions of the canvas (y up), radius as a fraction of its longer side.
    struct Blob { let color: NSColor; let x: CGFloat; let y: CGFloat; let radius: CGFloat }
    let name: String
    let colors: [NSColor]
    var spectrum: Bool = false
    var blobs: [Blob] = []
    static func rgb(_ value: UInt32) -> NSColor { NSColor(calibratedRed: CGFloat((value>>16)&255)/255, green: CGFloat((value>>8)&255)/255, blue: CGFloat(value&255)/255, alpha:1) }
    private static func b(_ c: UInt32, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Blob { Blob(color: rgb(c), x: x, y: y, radius: r) }
    /// Mesh-like presets matching the swatches in the reference recording.
    static let gradients: [ODBackgroundStyle] = [
        .init(name:"Sunset",colors:[rgb(0xff718d),rgb(0xffad60)],spectrum:true),
        .init(name:"Daybreak",colors:[rgb(0x8ea8f2),rgb(0xe9e6f2),rgb(0xf8f6f6)],blobs:[b(0xa58bf0,0.05,1,0.5),b(0xf6b38a,0.98,0.98,0.4)]),
        .init(name:"Sorbet",colors:[rgb(0xf2e35c)],blobs:[b(0xf27ac0,0.9,0.95,0.6),b(0xe8453c,0.02,0.02,0.45),b(0x7cd69a,0.18,0.5,0.4),b(0x58c8f0,1,0.3,0.5)]),
        .init(name:"Cloud",colors:[rgb(0xf6f1f4)],blobs:[b(0xd9c3ec,0,1,0.7),b(0xf3b9cf,1,0,0.7)]),
        .init(name:"Lavender",colors:[rgb(0xedb4d4)],blobs:[b(0xb79ae6,0,1,0.7),b(0xf3a3c6,0.6,0.3,0.5),b(0xc9a0e8,1,0,0.6)]),
        .init(name:"Garden",colors:[rgb(0x1e3a2e)],blobs:[b(0xe23a3f,0.95,0.95,0.6),b(0xf08a3c,0.55,0,0.55),b(0x3e9d63,0.1,0.4,0.45),b(0x0b1410,0.05,0.95,0.45)]),
        .init(name:"Sky",colors:[rgb(0x6e8ff2)],blobs:[b(0x8fe0f4,0.05,0.05,0.55),b(0x8e7cf0,0,1,0.6),b(0x4d7bf0,1,0.5,0.6)]),
        .init(name:"Lagoon",colors:[rgb(0x2fb5d4)],blobs:[b(0x6fe9e2,0.55,0.4,0.6),b(0x2c9fd0,0,1,0.6)]),
        .init(name:"Ice",colors:[rgb(0xeef0fa)],blobs:[b(0xaebdf2,0,1,0.7),b(0xd8d0f4,1,0.8,0.5)]),
        .init(name:"Dusk",colors:[rgb(0x23264f)],blobs:[b(0x7d4bd8,0,1,0.7),b(0xf2795a,1,0,0.7)]),
        .init(name:"Mint",colors:[rgb(0xc9f2df)],blobs:[b(0x5fd3b0,0,0,0.7),b(0xf4f7c6,1,1,0.6)])
    ]
    static let solids: [ODBackgroundStyle] = zip(["White","Yellow","Lime","Green","Teal","Cyan","Blue","Charcoal","Purple","Pink","Red","Orange","Black"], [UInt32(0xefeeec),0xe8b434,0x8cc63c,0x2f9a5a,0x1f8f80,0x3eb4c8,0x3150d2,0x1f2b3b,0x7a45cc,0xe2559a,0xe0432f,0xf08a24,0x111111]).map { .init(name:$0.0,colors:[rgb($0.1)]) }
}

enum ODBackgroundRenderer {
    static func render(image: CGImage, style: ODBackgroundStyle, backgroundImage: CGImage? = nil, padding: CGFloat, corner: CGFloat, shadow: CGFloat, ratio: CGFloat?, maxDimension: CGFloat? = nil) -> CGImage? {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        var width = iw+padding*2, height = ih+padding*2
        if let ratio = ratio { if width/height < ratio { width = height*ratio } else { height = width/ratio } }
        let scale = min(1,(maxDimension ?? max(width,height))/max(width,height))
        let outWidth = max(1,Int((width*scale).rounded())), outHeight = max(1,Int((height*scale).rounded()))
        // Protect against an accidental enormous allocation while retaining full resolution for ordinary assets.
        guard outWidth <= 32768, outHeight <= 32768, Int64(outWidth)*Int64(outHeight) <= 160_000_000,
              let context = CGContext(data:nil,width:outWidth,height:outHeight,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x:scale,y:scale)
        let bounds = CGRect(x:0,y:0,width:width,height:height)
        if let backgroundImage = backgroundImage {
            let fillScale = max(width/CGFloat(backgroundImage.width),height/CGFloat(backgroundImage.height))
            let size = CGSize(width:CGFloat(backgroundImage.width)*fillScale,height:CGFloat(backgroundImage.height)*fillScale)
            context.draw(backgroundImage,in:CGRect(x:(width-size.width)/2,y:(height-size.height)/2,width:size.width,height:size.height))
        } else { drawBackdrop(style,context:context,bounds:bounds) }
        let rect = CGRect(x:(width-iw)/2,y:(height-ih)/2,width:iw,height:ih)
        let radius = min(corner,min(iw,ih)/2)
        let path = CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil)
        context.saveGState()
        if shadow > 0 {
            context.setShadow(offset:CGSize(width:0,height:-shadow*0.35),blur:shadow,color:NSColor.black.withAlphaComponent(0.34).cgColor)
        }
        // Composite the clipped image as a group so its actual alpha casts the
        // shadow, without putting an opaque plate behind transparent PNGs.
        context.beginTransparencyLayer(auxiliaryInfo:nil)
        context.saveGState(); context.addPath(path); context.clip()
        context.interpolationQuality = .high
        context.draw(image,in:rect)
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
        return context.makeImage()
    }
    static func drawBackdrop(_ style: ODBackgroundStyle, context: CGContext, bounds: CGRect) {
        if style.colors.count == 1 { context.setFillColor(style.colors[0].cgColor); context.fill(bounds) }
        else {
            let colors = style.colors.map { $0.cgColor } as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name:CGColorSpace.sRGB), colors:colors, locations:nil) {
                let start = style.spectrum ? CGPoint(x:bounds.minX,y:bounds.maxY) : CGPoint(x:bounds.midX,y:bounds.maxY)
                let end = style.spectrum ? CGPoint(x:bounds.maxX,y:bounds.minY) : CGPoint(x:bounds.midX,y:bounds.minY)
                context.drawLinearGradient(gradient,start:start,end:end,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
            }
        }
        let side = max(bounds.width,bounds.height)
        for blob in style.blobs {
            let point = CGPoint(x:bounds.minX+bounds.width*blob.x,y:bounds.minY+bounds.height*blob.y)
            let colors = [blob.color.cgColor,blob.color.withAlphaComponent(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors,locations:[0,1]) {
                context.drawRadialGradient(gradient,startCenter:point,startRadius:0,endCenter:point,endRadius:side*blob.radius,options:[])
            }
        }
        if style.spectrum {
            for (color, point, radius) in [(ODBackgroundStyle.rgb(0xffdc29),CGPoint(x:bounds.maxX*0.93,y:bounds.maxY*0.92),bounds.width*0.90),(ODBackgroundStyle.rgb(0x6547e5),CGPoint(x:bounds.maxX*0.95,y:bounds.minY),bounds.width*0.75)] {
                let colors = [color.cgColor,color.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors,locations:[0,1]) { context.drawRadialGradient(gradient,startCenter:point,startRadius:0,endCenter:point,endRadius:radius,options:[]) }
            }
        }
    }
}

private final class ODBackgroundSwatch: NSButton {
    let style: ODBackgroundStyle
    var selected = false { didSet { needsDisplay = true } }
    var handler: (() -> Void)?
    init(style: ODBackgroundStyle, frame: CGRect, id: String) {
        self.style = style
        super.init(frame:frame)
        isBordered = false
        title = ""
        target = self; action = #selector(invoke)
        odIdentifier(self,id)
        setAccessibilityLabel(style.name + " background")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
    override func draw(_ dirtyRect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx:0.5,dy:0.5)
        context.saveGState(); context.addPath(CGPath(roundedRect:rect,cornerWidth:6,cornerHeight:6,transform:nil)); context.clip()
        // The renderer works in y-up image space; buttons are flipped.
        if isFlipped { context.translateBy(x:0,y:bounds.height); context.scaleBy(x:1,y:-1) }
        ODBackgroundRenderer.drawBackdrop(style,context:context,bounds:rect)
        context.restoreGState()
        if selected {
            let ring = NSBezierPath(roundedRect:bounds.insetBy(dx:0.9,dy:0.9),xRadius:5.5,yRadius:5.5)
            odOrange.setStroke(); ring.lineWidth = 1.8; ring.stroke()
        } else {
            let line = NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6)
            NSColor.black.withAlphaComponent(0.08).setStroke(); line.lineWidth = 0.5; line.stroke()
        }
    }
}

private final class ODSliderRow: ODFlippedView {
    let slider: NSSlider
    private let valueLabel: NSTextField
    var handler: ((Double) -> Void)?
    var formatter: (Double) -> String
    /// `centerY` is the row's vertical centre in the editor surface.
    init(title: String, centerY: CGFloat, x: CGFloat = 18, width: CGFloat = 384, min: Double = 0, max: Double, value: Double, id: String, formatter: @escaping (Double)->String = { "\(Int($0.rounded())) px" }) {
        slider = NSSlider(value:value,minValue:min,maxValue:max,target:nil,action:nil)
        slider.cell = ODSliderCell()
        slider.minValue = min; slider.maxValue = max; slider.doubleValue = value
        valueLabel = NSTextField(labelWithString:"")
        self.formatter = formatter
        super.init(frame:CGRect(x:x,y:centerY-13,width:width,height:26))
        odRowLabel(title, x: 0, centerY: 13, width: 70, in: self)
        slider.controlSize = .small
        slider.frame = CGRect(x:72,y:3,width:width-130,height:20)
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(changed)
        odIdentifier(slider,id)
        addSubview(slider)
        valueLabel.frame = CGRect(x:width-56,y:5.5,width:56,height:15)
        valueLabel.font = .monospacedDigitSystemFont(ofSize:10.5,weight:.regular)
        valueLabel.textColor = NSColor.labelColor.withAlphaComponent(0.58)
        valueLabel.alignment = .right
        addSubview(valueLabel)
        updateLabel()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    var value: Double { get { slider.doubleValue } set { slider.doubleValue = newValue; updateLabel() } }
    private func updateLabel() { valueLabel.stringValue = formatter(slider.doubleValue) }
    @objc private func changed() { updateLabel(); handler?(slider.doubleValue) }
}

private final class ODBackgroundController: ODEditorController {
    let image: CGImage
    private let preview = ODPreviewView()
    private var style = ODBackgroundStyle.gradients[0]
    private var backdrop: CGImage?
    private var padding: ODSliderRow!, corner: ODSliderRow!, shadow: ODSliderRow!, ratioControl: ODRatioControl!
    private var swatches: [ODBackgroundSwatch] = []
    private var customColor: NSColorWell!
    private var currentRatio: CGFloat?
    private var defaultPadding: Double { 160 }
    private var defaultCorner: Double { 24 }
    private var defaultShadow: Double { 24 }
    init(url:URL,image:CGImage) {
        self.image = image
        super.init(url:url,title:"Add BG",saveTitle:"Save with Background",action:"background",size:CGSize(width:418,height:618))
        preview.frame = CGRect(x:12,y:52,width:394,height:313)
        preview.inset = 11
        odIdentifier(preview,"editor.background.preview")
        surface.addSubview(preview)
        odRowLabel("Background",x:16,centerY:395,in:surface)
        // Two horizontally scrolling rows; the last tile peeks out to show there is more.
        for (row, styles) in [ODBackgroundStyle.gradients,ODBackgroundStyle.solids].enumerated() {
            let scroll = NSScrollView(frame:CGRect(x:94,y:379.5+CGFloat(row)*34,width:275,height:31))
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
            scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
            let strip = ODFlippedView(frame:CGRect(x:0,y:0,width:CGFloat(styles.count)*32+2,height:31))
            for (index, entry) in styles.enumerated() {
                let swatch = ODBackgroundSwatch(style:entry,frame:CGRect(x:2+CGFloat(index)*32,y:2,width:27,height:27),id:"editor.background.\(row == 0 ? "gradient" : "solid").\(index)")
                swatch.handler = { [weak self, weak swatch] in
                    guard let self = self else { return }
                    self.style = entry; self.backdrop = nil
                    self.swatches.forEach { $0.selected = $0 === swatch }; self.refresh()
                }
                swatches.append(swatch); strip.addSubview(swatch)
            }
            scroll.documentView = strip
            surface.addSubview(scroll)
        }
        swatches.first?.selected = true
        let photo = ODActionButton("",frame:CGRect(x:375,y:381.5,width:27,height:27),identifier:"editor.background.customImage") { [weak self] in self?.chooseBackground() }
        photo.image = NSImage(systemSymbolName:"photo.badge.plus",accessibilityDescription:"Choose background image")
        photo.setAccessibilityLabel("Choose background image")
        surface.addSubview(photo)
        customColor = NSColorWell(frame:CGRect(x:373,y:421,width:32,height:16))
        customColor.colorWellStyle = .minimal
        customColor.color = ODBackgroundStyle.rgb(0x2f5fc8)
        customColor.target = self; customColor.action = #selector(colorChanged)
        odIdentifier(customColor,"editor.background.customColor")
        surface.addSubview(customColor)
        let long = Double(max(image.width,image.height))
        padding = ODSliderRow(title:"Padding",centerY:462,x:16,width:386,max:max(400,long*0.625),value:defaultPadding,id:"editor.background.padding")
        corner = ODSliderRow(title:"Corners",centerY:488,x:16,width:386,max:max(100,long*0.24),value:defaultCorner,id:"editor.background.corners")
        shadow = ODSliderRow(title:"Shadow",centerY:514,x:16,width:386,max:160,value:defaultShadow,id:"editor.background.shadow")
        for row in [padding!,corner!,shadow!] { row.handler = { [weak self] _ in self?.refresh() }; surface.addSubview(row) }
        odRowLabel("Ratio",x:16,centerY:542,in:surface)
        ratioControl = ODRatioControl(labels:["Auto","1:1","16:9","4:5"],frame:CGRect(x:231,y:532,width:172,height:20),id:"editor.background.ratio") { [weak self] index in
            self?.currentRatio = [nil,CGFloat(1),CGFloat(16.0/9),CGFloat(4.0/5)][index]
            self?.refresh()
        }
        surface.addSubview(ratioControl)
        refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() { preview.image = render(maxDimension:820) }
    private func render(maxDimension:CGFloat? = nil) -> CGImage? {
        ODBackgroundRenderer.render(image:image,style:style,backgroundImage:backdrop,padding:CGFloat(padding.value),corner:CGFloat(corner.value),shadow:CGFloat(shadow.value),ratio:currentRatio,maxDimension:maxDimension)
    }
    @objc private func colorChanged() { style = .init(name:"Custom",colors:[customColor.color]); backdrop = nil; swatches.forEach { $0.selected = false }; refresh() }
    private func chooseBackground() {
        guard let window = window else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.beginSheetModal(for:window) { [weak self] response in
            guard let self = self, response == .OK, let url = picker.url else { return }
            do { self.backdrop = try MediaEngine.loadImage(url); self.swatches.forEach { $0.selected = false }; self.refresh() }
            catch { self.report(error) }
        }
    }
    override func resetEditor() {
        style = ODBackgroundStyle.gradients[0]; backdrop = nil
        swatches.forEach { $0.selected = false }; swatches.first?.selected = true
        padding.value = defaultPadding; corner.value = defaultCorner; shadow.value = defaultShadow
        currentRatio = nil; ratioControl.selectedSegment = 0; refresh()
    }
    override func saveEditor() { saveImage(render(),suffix:" With Background") }
}

private final class ODAdjustmentController: ODEditorController {
    let original: CGImage
    private let preview = ODPreviewView()
    private var brightness: ODSliderRow!, contrast: ODSliderRow!, saturation: ODSliderRow!
    private var quarterTurns = 0, flipped = false
    init(url:URL,image:CGImage) {
        original = image
        super.init(url:url,title:"Edit Image",saveTitle:"Save",action:"edit")
        preview.frame = CGRect(x:16,y:53,width:388,height:344)
        odIdentifier(preview,"editor.edit.preview"); surface.addSubview(preview)
        brightness = ODSliderRow(title:"Brightness",centerY:425.5,min:-1,max:1,value:0,id:"editor.edit.brightness",formatter:{ String(format:"%+.0f%%",$0*100) })
        contrast = ODSliderRow(title:"Contrast",centerY:458.5,min:0,max:2,value:1,id:"editor.edit.contrast",formatter:{ String(format:"%.0f%%",$0*100) })
        saturation = ODSliderRow(title:"Saturation",centerY:491.5,min:0,max:2,value:1,id:"editor.edit.saturation",formatter:{ String(format:"%.0f%%",$0*100) })
        for row in [brightness!,contrast!,saturation!] { row.handler = { [weak self] _ in self?.refresh() }; surface.addSubview(row) }
        let rotate = ODActionButton("↻  Rotate 90°",frame:CGRect(x:94,y:530,width:112,height:25),identifier:"editor.edit.rotate") { [weak self] in guard let self = self else { return }; self.quarterTurns = (self.quarterTurns+1)%4; self.refresh() }
        let flip = ODActionButton("↔  Flip",frame:CGRect(x:218,y:530,width:106,height:25),identifier:"editor.edit.flip") { [weak self] in self?.flipped.toggle(); self?.refresh() }
        surface.addSubview(rotate); surface.addSubview(flip); refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func render(previewOnly:Bool = false) -> CGImage? {
        var input = CIImage(cgImage:original)
        if previewOnly {
            let scale = min(1,900/max(input.extent.width,input.extent.height))
            input = input.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        }
        var result = input.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:brightness.value,kCIInputContrastKey:contrast.value,kCIInputSaturationKey:saturation.value])
        if flipped { result = result.oriented(.upMirrored) }
        for _ in 0..<quarterTurns { result = result.oriented(.right) }
        return CIContext(options:[.useSoftwareRenderer:false]).createCGImage(result,from:result.extent)
    }
    private func refresh() { preview.image = render(previewOnly:true) }
    override func resetEditor() { brightness.value = 0; contrast.value = 1; saturation.value = 1; quarterTurns = 0; flipped = false; refresh() }
    override func saveEditor() { saveImage(render(),suffix:" Edited") }
}

private final class ODMarkupController: ODEditorController {
    private let canvas: ODAnnotationCanvas
    private let redaction: Bool
    private var toolControl: ODRatioControl?
    private var textField: NSTextField!
    private var color: NSColorWell!
    private var stroke: ODSliderRow!
    init(url:URL,image:CGImage,redaction:Bool) {
        self.redaction = redaction
        canvas = ODAnnotationCanvas(image:image)
        super.init(url:url,title:redaction ? "Redact Image" : "Annotate Image",saveTitle:redaction ? "Save Redacted" : "Save",action:redaction ? "redact" : "annotate")
        canvas.frame = CGRect(x:16,y:53,width:388,height:367)
        surface.addSubview(canvas)
        canvas.tool = redaction ? .redact : .pen
        if redaction {
            let info = odLabel("Drag over sensitive areas to cover them with solid pixels.",CGRect(x:24,y:435,width:372,height:36),in:surface,size:11,secondary:true)
            info.maximumNumberOfLines = 2
            odLabel("Exported redactions cannot be removed.",CGRect(x:24,y:479,width:372,height:20),in:surface,size:11,weight:.medium)
        } else {
            let tools = ODRatioControl(labels:["Pen","Rectangle","Arrow","Text"],frame:CGRect(x:30,y:430,width:360,height:27),id:"editor.annotate.tool") { [weak self] index in self?.canvas.tool = [.pen,.rectangle,.arrow,.text][index] }
            surface.addSubview(tools); toolControl = tools
            stroke = ODSliderRow(title:"Stroke",centerY:477.5,min:1,max:40,value:6,id:"editor.annotate.stroke")
            stroke.handler = { [weak self] value in self?.canvas.strokeWidth = CGFloat(value) }
            canvas.strokeWidth = 6; surface.addSubview(stroke)
            color = NSColorWell(frame:CGRect(x:24,y:504,width:35,height:25))
            color.color = odOrange; color.target = self; color.action = #selector(colorChanged)
            odIdentifier(color,"editor.annotate.color"); surface.addSubview(color); canvas.inkColor = odOrange
            textField = NSTextField(frame:CGRect(x:72,y:504,width:324,height:25))
            textField.placeholderString = "Text to place on the image"
            textField.stringValue = "Text"
            textField.font = .systemFont(ofSize:11)
            textField.target = self; textField.action = #selector(textChanged)
            odIdentifier(textField,"editor.annotate.text"); surface.addSubview(textField)
            NotificationCenter.default.addObserver(self,selector:#selector(textChanged),name:NSControl.textDidChangeNotification,object:textField)
            canvas.textValue = "Text"
        }
        let undo = ODActionButton("Undo",frame:CGRect(x:24,y:546,width:63,height:23),identifier:"editor.\(redaction ? "redact" : "annotate").undo") { [weak self] in self?.canvas.undo() }
        surface.addSubview(undo)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func colorChanged() { canvas.inkColor = color.color }
    @objc private func textChanged() { canvas.textValue = textField.stringValue }
    override func resetEditor() { canvas.clear() }
    override func saveEditor() { saveImage(canvas.renderedImage(),suffix:redaction ? " Redacted" : " Annotated") }
}

private final class ODCompressionController: ODEditorController {
    private let preview = ODPreviewView()
    private var quality: ODSliderRow!
    init(url:URL,image:CGImage?) {
        super.init(url:url,title:"Compress",saveTitle:"Compress & Save",action:"compress")
        preview.frame = CGRect(x:16,y:53,width:388,height:360); preview.image = image
        odIdentifier(preview,"editor.compress.preview"); surface.addSubview(preview)
        if image == nil {
            let icon = NSImageView(frame:CGRect(x:172,y:168,width:76,height:90)); icon.image = NSWorkspace.shared.icon(forFile:url.path); surface.addSubview(icon)
        }
        odLabel(url.lastPathComponent,CGRect(x:24,y:429,width:372,height:20),in:surface,size:12,weight:.medium)
        let bytes = (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
        odLabel("Original: \(ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file))",CGRect(x:24,y:456,width:372,height:18),in:surface,size:11,secondary:true)
        quality = ODSliderRow(title:"Quality",centerY:505.5,min:0.1,max:1,value:0.8,id:"editor.compress.quality",formatter:{ "\(Int(($0*100).rounded()))%" })
        surface.addSubview(quality)
        let note = odLabel("Lower quality makes a smaller file. A new copy is saved beside the original.",CGRect(x:24,y:537,width:372,height:32),in:surface,size:10,secondary:true); note.maximumNumberOfLines = 2
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetEditor() { quality.value = 0.8 }
    override func saveEditor() { let url = sourceURL, value = quality.value; performSave { try MediaEngine.compress(url,quality:value) } }
}

private final class ODMetadataController: ODEditorController {
    init(url:URL,entries:[(String,String)]) {
        super.init(url:url,title:"Metadata",saveTitle:"Strip Metadata",action:"metadata")
        surface.subviews.first(where:{ $0.identifier?.rawValue == "editor.metadata.reset" })?.isHidden = true
        odLabel(url.lastPathComponent,CGRect(x:20,y:57,width:380,height:22),in:surface,size:12,weight:.medium)
        let scroll = NSScrollView(frame:CGRect(x:16,y:91,width:388,height:438))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let text = NSTextView(frame:CGRect(x:0,y:0,width:370,height:438))
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.textContainerInset = CGSize(width:8,height:8)
        text.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        text.textColor = .labelColor
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.string = entries.isEmpty ? "No metadata found." : entries.map { "\($0.0)\n\($0.1)" }.joined(separator:"\n\n")
        odIdentifier(text,"editor.metadata.entries")
        scroll.documentView = text; surface.addSubview(scroll)
        let note = odLabel("Save a new copy with metadata removed.",CGRect(x:24,y:546,width:372,height:20),in:surface,size:10,secondary:true)
        note.maximumNumberOfLines = 2
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func saveEditor() { let url = sourceURL; performSave { try MediaEngine.stripMetadata(url) } }
}
