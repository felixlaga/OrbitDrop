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

    public func open(action: String, url: URL, onSaved: @escaping (URL) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.open(action: action, url: url, onSaved: onSaved) }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        do {
            let window = try makeOffscreenWindow(action: action, url: url, onSaved: onSaved)
            (window.windowController as? ODEditorController)?.presentsErrors = true
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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

private let odOrange = NSColor(calibratedRed: 0.92, green: 0.29, blue: 0.055, alpha: 1)

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

private final class ODActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, frame: NSRect, identifier: String, primary: Bool = false, handler: (() -> Void)? = nil) {
        super.init(frame: frame)
        self.title = title
        self.handler = handler
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityIdentifier(identifier)
        font = .systemFont(ofSize: 11, weight: primary ? .semibold : .medium)
        bezelStyle = .rounded
        controlSize = .small
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = (primary ? odOrange : NSColor.labelColor.withAlphaComponent(0.065)).cgColor
        contentTintColor = primary ? .white : .labelColor
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font!, .foregroundColor: primary ? NSColor.white : NSColor.labelColor])
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
}

@discardableResult
private func odLabel(_ text: String, _ frame: NSRect, in parent: NSView, size: CGFloat = 11, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.frame = frame
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    label.lineBreakMode = .byTruncatingTail
    parent.addSubview(label)
    return label
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

class ODEditorController: NSWindowController, NSWindowDelegate {
    let sourceURL: URL
    let surface = ODFlippedView(frame: CGRect(x: 0, y: 0, width: 420, height: 630))
    var onSaved: ((URL) -> Void)?
    var onClosed: (() -> Void)?
    var presentsErrors = false
    private(set) var lastError: Error?
    private(set) var saveButton: NSButton!
    private var status: NSTextField!
    private var isSaving = false

    init(url: URL, title: String, saveTitle: String, action: String) {
        sourceURL = url
        let panel = ODEditorPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 630), styleMask: [.borderless], backing: .buffered, defer: false)
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
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 22
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 0.75
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
        panel.contentView = surface
        let glass = NSVisualEffectView(frame: surface.bounds)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        glass.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.73, blue: 0.38, alpha: 0.065).cgColor
        surface.addSubview(glass)
        let titleBar = ODTitleBar(frame: CGRect(x: 0, y: 0, width: 420, height: 40))
        surface.addSubview(titleBar)
        let heading = odLabel(title, CGRect(x: 58, y: 12, width: 304, height: 20), in: titleBar, size: 13, weight: .semibold)
        heading.alignment = .center
        let close = ODActionButton("×", frame: CGRect(x: 13, y: 11, width: 20, height: 20), identifier: "editor.\(action).close") { [weak self] in self?.close() }
        close.font = .systemFont(ofSize: 16)
        close.layer?.cornerRadius = 10
        close.setAccessibilityLabel("Close \(title)")
        titleBar.addSubview(close)
        separator(y: 40)
        separator(y: 582)
        let reset = ODActionButton("Reset", frame: CGRect(x: 16, y: 600, width: 48, height: 21), identifier: "editor.\(action).reset") { [weak self] in self?.resetEditor() }
        surface.addSubview(reset)
        let width = max(58, CGFloat(saveTitle.count) * 6.15 + 16)
        let save = ODActionButton(saveTitle, frame: CGRect(x: 404 - width, y: 600, width: width, height: 21), identifier: "editor.\(action).save", primary: true) { [weak self] in self?.saveEditor() }
        save.keyEquivalent = "\r"
        saveButton = save
        surface.addSubview(save)
        status = odLabel("", CGRect(x: 72, y: 603, width: max(40, 324 - width), height: 16), in: surface, size: 10, secondary: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func separator(y: CGFloat) {
        let line = NSView(frame: CGRect(x: 0, y: y, width: 420, height: 0.5))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
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
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        if let image = image { odDraw(image, in: odFit(CGSize(width: image.width, height: image.height), in: bounds.insetBy(dx: inset, dy: inset))) }
    }
}

private final class ODRatioControl: NSSegmentedControl {
    var handler: ((Int) -> Void)?
    override var selectedSegment: Int { didSet { needsDisplay = true } }
    init(labels: [String], frame: CGRect, id: String, handler: @escaping (Int) -> Void) {
        super.init(frame: frame)
        segmentCount = labels.count
        for (index, label) in labels.enumerated() { setLabel(label, forSegment: index); setWidth(frame.width / CGFloat(labels.count), forSegment: index) }
        trackingMode = .selectOne
        segmentStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 10)
        selectedSegment = 0
        self.handler = handler
        target = self
        action = #selector(changed)
        odIdentifier(self, id)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { handler?(selectedSegment) }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 3)
        NSColor.labelColor.withAlphaComponent(0.075).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let width = rect.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let part = CGRect(x: rect.minX + CGFloat(index)*width, y: rect.minY, width: width, height: rect.height)
            if index == selectedSegment {
                odOrange.setFill()
                NSBezierPath(roundedRect: part, xRadius: 4, yRadius: 4).fill()
            }
            let label = (label(forSegment:index) ?? "") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font:NSFont.systemFont(ofSize:10,weight:index == selectedSegment ? .semibold : .regular),.foregroundColor:index == selectedSegment ? NSColor.white : NSColor.labelColor.withAlphaComponent(0.72)]
            let size = label.size(withAttributes:attributes)
            label.draw(at:CGPoint(x:part.midX-size.width/2,y:part.midY-size.height/2),withAttributes:attributes)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        selectedSegment = max(0,min(segmentCount-1,Int(point.x / bounds.width * CGFloat(segmentCount))))
        handler?(selectedSegment)
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
            let size = index % 2 == 0 ? CGSize(width: 8, height: 8) : ((index == 1 || index == 5) ? CGSize(width: 17, height: 4) : CGSize(width: 4, height: 17))
            NSBezierPath(roundedRect: CGRect(x: p.x-size.width/2, y:p.y-size.height/2, width:size.width,height:size.height), xRadius:2,yRadius:2).fill()
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
        var size = selection.size
        if size.width / size.height > ratio { size.width = size.height*ratio } else { size.height = size.width/ratio }
        selection = bounded(CGRect(x: selection.midX-size.width/2, y: selection.midY-size.height/2, width:size.width,height:size.height))
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
        super.init(url: url, title: "Crop Image", saveTitle: "Apply", action: "crop")
        canvas.frame = CGRect(x: 30, y: 52, width: 360, height: 418)
        surface.addSubview(canvas)
        odLabel("Aspect ratio", CGRect(x:18,y:490,width:92,height:18), in:surface, size:11, secondary:true)
        ratio = ODRatioControl(labels: ["Free","1:1","16:9","9:16","4:3","3:4"], frame:CGRect(x:128,y:486,width:274,height:24), id:"editor.crop.ratio") { [weak self] index in
            let ratios: [CGFloat?] = [nil,1,16.0/9,9.0/16,4.0/3,3.0/4]
            self?.canvas.setRatio(ratios[index])
        }
        surface.addSubview(ratio)
        odLabel("W", CGRect(x:18,y:529,width:14,height:17), in:surface, size:10, secondary:true)
        odLabel("H", CGRect(x:113,y:529,width:14,height:17), in:surface, size:10, secondary:true)
        odLabel("px", CGRect(x:211,y:529,width:28,height:17), in:surface, size:10, secondary:true)
        for (field, x, id) in [(widthField,CGFloat(35),"editor.crop.width"),(heightField,CGFloat(130),"editor.crop.height")] {
            field.frame = CGRect(x:x,y:524,width:73,height:24)
            field.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
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
    let name: String
    let colors: [NSColor]
    var spectrum: Bool = false
    static func rgb(_ value: UInt32) -> NSColor { NSColor(calibratedRed: CGFloat((value>>16)&255)/255, green: CGFloat((value>>8)&255)/255, blue: CGFloat(value&255)/255, alpha:1) }
    static let gradients: [ODBackgroundStyle] = [
        .init(name:"Sunset",colors:[rgb(0xff718d),rgb(0xffad60)],spectrum:true),
        .init(name:"Daybreak",colors:[rgb(0x7199ff),rgb(0xffc687),rgb(0xffffff)]),
        .init(name:"Sorbet",colors:[rgb(0xfa8ce3),rgb(0xdff36b),rgb(0x5edbd9)]),
        .init(name:"Cloud",colors:[rgb(0xa7c5f6),rgb(0xffeef2),rgb(0xffffff)]),
        .init(name:"Lavender",colors:[rgb(0x8885e5),rgb(0xe6b4eb),rgb(0xffdfc7)]),
        .init(name:"Garden",colors:[rgb(0x123d35),rgb(0x68b77e),rgb(0xf86b83)]),
        .init(name:"Sky",colors:[rgb(0x9c9cf1),rgb(0x64b7ed),rgb(0x6de7dc)]),
        .init(name:"Lagoon",colors:[rgb(0x4778ad),rgb(0x38c3c7),rgb(0xa6efeb)]),
        .init(name:"Ice",colors:[rgb(0x5d8bdf),rgb(0xe0c8ec),rgb(0xe8f4ff)])
    ]
    static let solids: [ODBackgroundStyle] = zip(["White","Yellow","Lime","Green","Teal","Cyan","Blue","Charcoal","Purple"], [UInt32(0xf5f5f1),0xf2c53a,0x94ce34,0x429768,0x258e88,0x48b6c7,0x3a5fce,0x273849,0x7953bc]).map { .init(name:$0.0,colors:[rgb($0.1)]) }
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
        if style.colors.count == 1 { context.setFillColor(style.colors[0].cgColor); context.fill(bounds); return }
        let colors = style.colors.map { $0.cgColor } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name:CGColorSpace.sRGB), colors:colors, locations:nil) {
            context.drawLinearGradient(gradient,start:CGPoint(x:bounds.minX,y:bounds.maxY),end:CGPoint(x:bounds.maxX,y:bounds.minY),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
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
        let rect = bounds.insetBy(dx:2,dy:2)
        context.saveGState(); context.addPath(CGPath(roundedRect:rect,cornerWidth:5,cornerHeight:5,transform:nil)); context.clip()
        ODBackgroundRenderer.drawBackdrop(style,context:context,bounds:rect)
        context.restoreGState()
        let line = NSBezierPath(roundedRect:rect,xRadius:5,yRadius:5)
        (selected ? odOrange : NSColor.white.withAlphaComponent(0.22)).setStroke(); line.lineWidth = selected ? 2 : 0.5; line.stroke()
    }
}

private final class ODOrangeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = CGRect(x:rect.minX,y:rect.midY-1.5,width:rect.width,height:3)
        NSColor.white.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect:track,xRadius:1.5,yRadius:1.5).fill()
        let fraction = (doubleValue-minValue)/max(0.0001,maxValue-minValue)
        let progress = CGRect(x:track.minX,y:track.minY,width:track.width*CGFloat(fraction),height:track.height)
        odOrange.setFill()
        NSBezierPath(roundedRect:progress,xRadius:1.5,yRadius:1.5).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let knob = CGRect(x:knobRect.midX-7,y:knobRect.midY-7,width:14,height:14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowOffset = CGSize(width:0,height:-0.5); shadow.shadowBlurRadius = 1.5; shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.set()
        NSColor(calibratedWhite:0.97,alpha:1).setFill(); NSBezierPath(ovalIn:knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class ODSliderRow: ODFlippedView {
    let slider: NSSlider
    private let valueLabel: NSTextField
    var handler: ((Double) -> Void)?
    var formatter: (Double) -> String
    init(title: String, y: CGFloat, min: Double = 0, max: Double, value: Double, id: String, formatter: @escaping (Double)->String = { "\(Int($0.rounded())) px" }) {
        slider = NSSlider(value:value,minValue:min,maxValue:max,target:nil,action:nil)
        slider.cell = ODOrangeSliderCell()
        slider.minValue = min; slider.maxValue = max; slider.doubleValue = value
        valueLabel = NSTextField(labelWithString:"")
        self.formatter = formatter
        super.init(frame:CGRect(x:18,y:y,width:384,height:25))
        odLabel(title,CGRect(x:0,y:6,width:75,height:16),in:self,size:10,secondary:true)
        slider.frame = CGRect(x:78,y:2,width:254,height:21)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(changed)
        odIdentifier(slider,id)
        addSubview(slider)
        valueLabel.frame = CGRect(x:330,y:6,width:54,height:15)
        valueLabel.font = .monospacedDigitSystemFont(ofSize:10,weight:.regular)
        valueLabel.textColor = .secondaryLabelColor
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
    private var defaultCorner: Double { min(184,Double(min(image.width,image.height))/2) }
    init(url:URL,image:CGImage) {
        self.image = image
        super.init(url:url,title:"Add BG",saveTitle:"Save with Background",action:"background")
        preview.frame = CGRect(x:14,y:51,width:392,height:323)
        preview.inset = 12
        odIdentifier(preview,"editor.background.preview")
        surface.addSubview(preview)
        odLabel("Background",CGRect(x:18,y:396,width:77,height:16),in:surface,size:10,secondary:true)
        for (row, styles) in [ODBackgroundStyle.gradients,ODBackgroundStyle.solids].enumerated() {
            for (index, entry) in styles.enumerated() {
                let swatch = ODBackgroundSwatch(style:entry,frame:CGRect(x:96+CGFloat(index)*30.5,y:388+CGFloat(row)*31,width:28,height:28),id:"editor.background.\(row == 0 ? "gradient" : "solid").\(index)")
                swatch.handler = { [weak self, weak swatch] in
                    guard let self = self else { return }
                    self.style = entry; self.backdrop = nil
                    self.swatches.forEach { $0.selected = $0 === swatch }; self.refresh()
                }
                swatches.append(swatch); surface.addSubview(swatch)
            }
        }
        swatches.first?.selected = true
        let photo = ODActionButton("",frame:CGRect(x:371,y:391,width:28,height:24),identifier:"editor.background.customImage") { [weak self] in self?.chooseBackground() }
        photo.image = NSImage(systemSymbolName:"photo.badge.plus",accessibilityDescription:"Choose background image")
        photo.imagePosition = .imageOnly
        surface.addSubview(photo)
        customColor = NSColorWell(frame:CGRect(x:373,y:424,width:24,height:18))
        customColor.color = ODBackgroundStyle.rgb(0x3264bc)
        customColor.target = self; customColor.action = #selector(colorChanged)
        odIdentifier(customColor,"editor.background.customColor")
        surface.addSubview(customColor)
        padding = ODSliderRow(title:"Padding",y:459,max:max(320,Double(max(image.width,image.height))*0.65),value:defaultPadding,id:"editor.background.padding")
        corner = ODSliderRow(title:"Corners",y:486,max:Double(min(image.width,image.height))/2,value:defaultCorner,id:"editor.background.corners")
        shadow = ODSliderRow(title:"Shadow",y:513,max:120,value:24,id:"editor.background.shadow")
        for row in [padding!,corner!,shadow!] { row.handler = { [weak self] _ in self?.refresh() }; surface.addSubview(row) }
        odLabel("Ratio",CGRect(x:18,y:552,width:58,height:16),in:surface,size:10,secondary:true)
        ratioControl = ODRatioControl(labels:["Auto","1:1","16:9","4:5"],frame:CGRect(x:225,y:546,width:177,height:24),id:"editor.background.ratio") { [weak self] index in
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
        padding.value = defaultPadding; corner.value = defaultCorner; shadow.value = 24
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
        brightness = ODSliderRow(title:"Brightness",y:413,min:-1,max:1,value:0,id:"editor.edit.brightness",formatter:{ String(format:"%+.0f%%",$0*100) })
        contrast = ODSliderRow(title:"Contrast",y:446,min:0,max:2,value:1,id:"editor.edit.contrast",formatter:{ String(format:"%.0f%%",$0*100) })
        saturation = ODSliderRow(title:"Saturation",y:479,min:0,max:2,value:1,id:"editor.edit.saturation",formatter:{ String(format:"%.0f%%",$0*100) })
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
            stroke = ODSliderRow(title:"Stroke",y:465,min:1,max:40,value:6,id:"editor.annotate.stroke")
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
        quality = ODSliderRow(title:"Quality",y:493,min:0.1,max:1,value:0.8,id:"editor.compress.quality",formatter:{ "\(Int(($0*100).rounded()))%" })
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
