import AppKit

struct WheelAction {
    let label: String
    let symbol: String?
    let key: String
    static let tools: [WheelAction] = [
        .init(label: "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", key: "compress"),
        .init(label: "METADATA", symbol: "tag", key: "metadata"),
        .init(label: "EDIT", symbol: "slider.horizontal.3", key: "edit"),
        .init(label: "ANNOTATE", symbol: "pencil.tip.crop.circle", key: "annotate"),
        .init(label: "ADD BG", symbol: "photo", key: "background"),
        .init(label: "CROP", symbol: "crop", key: "crop"),
        .init(label: "REDACT", symbol: "eye.slash", key: "redact")
    ]
    static func formats(for url: URL?) -> [WheelAction] {
        let ext = url?.pathExtension.lowercased() ?? "png"
        let formats = ext == "pdf" ? ["DOCX", "JPG", "PNG", "TXT"] : ["PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "DOCX"]
        return formats.map { .init(label: $0, symbol: nil, key: $0.lowercased()) }
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class RadialMenu: NSView {
    var actions: [WheelAction] = [] { didSet { hovered = nil; buildAccessibility(); needsDisplay = true } }
    var file: URL? { didSet { needsDisplay = true } }
    var files: [URL] = []
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    var busyLabel: String? { didSet { needsDisplay = true } }
    var onAction: ((WheelAction, [URL]) -> Void)?
    var onToggle: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDragModifiers: ((NSEvent.ModifierFlags) -> Void)?
    var isTools = false
    private var centerMouseDown: NSPoint?
    private var centerWindowOrigin: NSPoint?
    private var centerDidMove = false
    private var provisionalFiles: [URL] = []
    private var originalDragActions: [WheelAction]?
    private var tracking: NSTrackingArea?
    private var actionElements: [NSAccessibilityElement] = []
    let accent = NSColor(srgbRed: 1, green: 0.26, blue: 0.035, alpha: 1)
    var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    var outerRadius: CGFloat { min(bounds.width, bounds.height) / 2 - 9 }
    let innerRadius: CGFloat = 74

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        setAccessibilityElement(false)
        setAccessibilityLabel("OrbitDrop radial menu")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x-center.x, point.y-center.y) < innerRadius {
            centerMouseDown = NSEvent.mouseLocation
            centerWindowOrigin = window?.frame.origin
            centerDidMove = false
            return
        }
        if let i = index(at: point) { execute(i, urls: files) }
        else { onDismiss?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = centerMouseDown, let origin = centerWindowOrigin else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x-start.x, dy = point.y-start.y
        if hypot(dx,dy)>3 { centerDidMove = true }
        if centerDidMove { window?.setFrameOrigin(NSPoint(x:origin.x+dx,y:origin.y+dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if centerMouseDown != nil && !centerDidMove { onToggle?() }
        centerMouseDown = nil; centerWindowOrigin = nil; centerDidMove = false
    }
    override func rightMouseDown(with event: NSEvent) { onToggle?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() }
        else if event.keyCode == 48 || event.charactersIgnoringModifiers == " " { onToggle?() }
        else if let n = Int(event.charactersIgnoringModifiers ?? ""), n > 0, n <= actions.count { execute(n-1, urls: files) }
        else { super.keyDown(with: event) }
    }
    func index(at point: NSPoint) -> Int? {
        let dx = point.x-center.x, dy = point.y-center.y
        let r = hypot(dx,dy)
        guard r >= innerRadius+3, r <= outerRadius-3, !actions.isEmpty else { return nil }
        let angle = (90 - atan2(dy,dx)*180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let step = 360.0 / Double(actions.count)
        return Int(floor((Double(angle)+step/2)/step)) % actions.count
    }
    func execute(_ index: Int, urls: [URL]) {
        guard busyLabel == nil, index >= 0, index < actions.count, !urls.isEmpty else { return }
        onAction?(actions[index], urls)
    }
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard busyLabel == nil else { return [] }
        let urls = Self.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        if originalDragActions == nil { originalDragActions = actions }
        provisionalFiles = urls
        onDragModifiers?(NSEvent.modifierFlags)
        if !isTools {
            let formats = WheelAction.formats(for:urls.first)
            if formats.map(\.key) != actions.map(\.key) { actions = formats }
        }
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        return hovered == nil ? [] : .copy
    }
    private func clearProvisionalDrag() {
        provisionalFiles = []
        if originalDragActions != nil { actions = isTools ? WheelAction.tools : WheelAction.formats(for:file) }
        originalDragActions = nil
        hovered = nil
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearProvisionalDrag(); onDragExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { busyLabel == nil && hovered != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard busyLabel == nil, let i = index(at: convert(sender.draggingLocation, from: nil)), actions.indices.contains(i) else { return false }
        let urls = Self.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let action = actions[i]
        DispatchQueue.main.async { self.onAction?(action, urls) }
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearProvisionalDrag() }
    private func polar(_ radius: CGFloat, _ angle: CGFloat) -> NSPoint {
        NSPoint(x: center.x+radius*cos(angle * .pi/180), y: center.y+radius*sin(angle * .pi/180))
    }
    func wedge(_ i: Int) -> NSBezierPath {
        let step = CGFloat(360)/CGFloat(actions.count)
        let a = 90-CGFloat(i)*step-step/2+0.85
        let b = a+step-1.7
        let ro = outerRadius-8, ri = innerRadius+6, cr: CGFloat = actions.count <= 4 ? 18 : 13
        let da = cr/ro*180 / .pi, di = cr/ri*180 / .pi
        let p = NSBezierPath()
        p.move(to: polar(ri+cr,a))
        p.line(to: polar(ro-cr,a))
        p.curve(to: polar(ro,a+da), controlPoint1: polar(ro,a), controlPoint2: polar(ro,a))
        p.appendArc(withCenter: center, radius: ro, startAngle: a+da, endAngle: b-da)
        p.curve(to: polar(ro-cr,b), controlPoint1: polar(ro,b), controlPoint2: polar(ro,b))
        p.line(to: polar(ri+cr,b))
        p.curve(to: polar(ri,b-di), controlPoint1: polar(ri,b), controlPoint2: polar(ri,b))
        p.appendArc(withCenter: center, radius: ri, startAngle: b-di, endAngle: a+di, clockwise: true)
        p.curve(to: polar(ri+cr,a), controlPoint1: polar(ri,a), controlPoint2: polar(ri,a))
        p.close()
        return p
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8))
        NSColor.white.withAlphaComponent(0.08).setFill(); circle.fill()
        NSColor.white.withAlphaComponent(0.62).setStroke(); circle.lineWidth = 1.7; circle.stroke()
        for (i, action) in actions.enumerated() {
            let path = wedge(i)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.13)
            shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
            if hovered == i {
                let g = NSGradient(starting: NSColor(srgbRed: 1, green: 0.43, blue: 0.04, alpha: 0.98), ending: accent)!
                g.draw(in: path, angle: -80)
            } else {
                let g = NSGradient(starting: NSColor.white.withAlphaComponent(0.60), ending: NSColor(srgbRed: 1, green: 0.91, blue: 0.83, alpha: 0.47))!
                g.draw(in: path, angle: -90)
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(hovered == i ? 0.16 : 0.44).setStroke(); path.lineWidth = 0.8; path.stroke()
            let angle = 90-CGFloat(i)*360/CGFloat(actions.count)
            let pos = polar((outerRadius+innerRadius)/2-1,angle)
            let color = hovered == i ? NSColor.white : NSColor(srgbRed: 0.15,green: 0.12,blue: 0.10,alpha: 1)
            if let symbol = action.symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                icon.withSymbolConfiguration(cfg)?.draw(in: NSRect(x:pos.x-12,y:pos.y+1,width:24,height:24))
            }
            let fontSize: CGFloat = action.symbol == nil ? (actions.count == 4 ? 16 : 13.5) : 11.2
            let text = NSAttributedString(string: action.label, attributes: [.font:NSFont.systemFont(ofSize:fontSize,weight:.semibold),.foregroundColor:color,.kern:action.symbol == nil ? 0 : 0.35])
            let size = text.size()
            text.draw(at: NSPoint(x:pos.x-size.width/2,y:pos.y-(action.symbol == nil ? size.height/2 : 18)))
        }
        let centerRing = NSBezierPath(ovalIn: NSRect(x:center.x-innerRadius,y:center.y-innerRadius,width:innerRadius*2,height:innerRadius*2))
        NSColor.white.withAlphaComponent(0.36).setStroke(); centerRing.lineWidth = 1.2; centerRing.stroke()
        let pill = NSBezierPath(roundedRect: NSRect(x:center.x-57,y:center.y-24,width:114,height:48),xRadius:24,yRadius:24)
        NSGradient(starting: .white.withAlphaComponent(0.62), ending: .white.withAlphaComponent(0.36))!.draw(in:pill,angle:-90)
        NSColor.white.withAlphaComponent(0.38).setStroke(); pill.lineWidth = 1; pill.stroke()
        let displayFiles = provisionalFiles.isEmpty ? files : provisionalFiles
        let label: String
        if let busyLabel { label = busyLabel }
        else if let hovered, actions.indices.contains(hovered) { label = actions[hovered].label }
        else if displayFiles.count > 1 { label = "\(displayFiles.count) files" }
        else if let file = provisionalFiles.first ?? file, let bytes = try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize {
            label = ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file)
        } else { label = isTools ? "TOOLS" : "CONVERT" }
        let text = NSAttributedString(string:label,attributes:[.font:NSFont.systemFont(ofSize:12.5,weight:.semibold),.foregroundColor:NSColor(srgbRed:0.17,green:0.13,blue:0.1,alpha:1)])
        text.draw(at:NSPoint(x:center.x-text.size().width/2,y:center.y-text.size().height/2))
        NSGraphicsContext.restoreGraphicsState()
    }
    private func buildAccessibility() {
        actionElements = actions.enumerated().map { i, action in
            let el = WheelAccessibilityElement(); el.owner = self; el.index = i
            el.setAccessibilityRole(.button); el.setAccessibilityLabel(action.label)
            el.setAccessibilityEnabled(true)
            el.setAccessibilityIdentifier("wheel-"+action.key)
            el.setAccessibilityParent(self)
            return el
        }
    }
    override func accessibilityChildren() -> [Any]? { actionElements }
}

final class WheelAccessibilityElement: NSAccessibilityElement {
    weak var owner: RadialMenu?
    var index = 0
    override func accessibilityPerformPress() -> Bool {
        guard let owner else { return false }; owner.execute(index,urls:owner.files); return true
    }
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(owner.wedge(index).bounds,to:nil))
    }
}
