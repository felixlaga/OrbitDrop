import AppKit

struct WheelAction {
    let label: String
    let symbol: String?
    let key: String
    static let tools: [WheelAction] = [
        .init(label: "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", key: "compress"),
        .init(label: "METADATA", symbol: "tag", key: "metadata"),
        .init(label: "EDIT", symbol: "slider.horizontal.3", key: "edit"),
        .init(label: "ANNOTATE", symbol: "pencil.and.outline", key: "annotate"),
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

/// Measurements in points, taken from the reference recording.
enum WheelGeometry {
    static let radius: CGFloat = 119
    static let wedgeOuter: CGFloat = 112
    static let wedgeInner: CGFloat = 47
    static let hole: CGFloat = 41
    static let gap: CGFloat = 6
    static let outerCorner: CGFloat = 10
    static let innerCorner: CGFloat = 6
    static let pill = CGSize(width: 68, height: 34)
    static let margin: CGFloat = 14
    static var panelSize: CGFloat { (radius + margin) * 2 }
}

let orbitAccent = NSColor(srgbRed: 0.94, green: 0.34, blue: 0.10, alpha: 1)

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
    /// Labels fade in just after the wedges when the wheel opens.
    @objc dynamic var labelAlpha: CGFloat = 1 { didSet { needsDisplay = true } }
    /// True when a glass view behind this one already provides the ring's backdrop.
    var hasGlassBackdrop = false { didSet { needsDisplay = true } }
    var onAction: ((WheelAction, [URL]) -> Void)?
    var onToggle: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDragUpdate: (() -> Void)?
    var isTools = false
    private var centerMouseDown: NSPoint?
    private var centerWindowOrigin: NSPoint?
    private var centerDidMove = false
    private var provisionalFiles: [URL] = []
    private var tracking: NSTrackingArea?
    private var actionElements: [NSAccessibilityElement] = []
    var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        setAccessibilityElement(false)
        setAccessibilityLabel("OrbitDrop radial menu")
    }
    required init?(coder: NSCoder) { fatalError() }
    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "labelAlpha" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hypot(local.x-center.x, local.y-center.y) <= WheelGeometry.radius ? self : nil
    }
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
        if hypot(point.x-center.x, point.y-center.y) < WheelGeometry.wedgeInner {
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
        if hypot(dx, dy) > 3 { centerDidMove = true }
        if centerDidMove { window?.setFrameOrigin(NSPoint(x: origin.x+dx, y: origin.y+dy)) }
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

    /// Wedge under a point. The thin glass gaps belong to the nearest wedge so a
    /// drop never falls between two targets.
    func index(at point: NSPoint) -> Int? {
        let dx = point.x-center.x, dy = point.y-center.y
        let r = hypot(dx, dy)
        guard r >= WheelGeometry.wedgeInner - WheelGeometry.gap/2, r <= WheelGeometry.radius, !actions.isEmpty else { return nil }
        let angle = (90 - atan2(dy, dx)*180 / .pi + 360).truncatingRemainder(dividingBy: 360)
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

    // MARK: Drag destination
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard busyLabel == nil else { return [] }
        let urls = Self.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        if provisionalFiles != urls {
            provisionalFiles = urls
            if !isTools {
                let formats = WheelAction.formats(for: urls.first)
                if formats.map(\.key) != actions.map(\.key) { actions = formats }
            }
            needsDisplay = true
        }
        onDragUpdate?()
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        return hovered == nil ? [] : .copy
    }
    private func clearProvisionalDrag() {
        provisionalFiles = []
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

    // MARK: Geometry
    private func unit(_ degrees: CGFloat) -> CGVector {
        CGVector(dx: cos(degrees * .pi/180), dy: sin(degrees * .pi/180))
    }
    private func point(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        let u = unit(degrees); return CGPoint(x: center.x+u.dx*radius, y: center.y+u.dy*radius)
    }
    private func degrees(of p: CGPoint, around c: CGPoint) -> CGFloat { atan2(p.y-c.y, p.x-c.x)*180 / .pi }
    /// Foot of the perpendicular from `p` onto a wedge edge that runs parallel to
    /// the radius at `angle`, shifted `offset` points sideways.
    private func project(_ p: CGPoint, angle: CGFloat, offset: CGFloat) -> CGPoint {
        let u = unit(angle), n = unit(angle+90)
        let t = (p.x-center.x)*u.dx + (p.y-center.y)*u.dy
        return CGPoint(x: center.x+u.dx*t+n.dx*offset, y: center.y+u.dy*t+n.dy*offset)
    }
    private func addShortArc(_ path: CGMutablePath, around c: CGPoint, radius: CGFloat, from a: CGPoint, to b: CGPoint) {
        let start = atan2(a.y-c.y, a.x-c.x), end = atan2(b.y-c.y, b.x-c.x)
        var sweep = end-start
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        path.addArc(center: c, radius: radius, startAngle: start, endAngle: start+sweep, clockwise: sweep < 0)
    }

    /// A rounded annular sector with parallel, constant-width gaps to its neighbours.
    func wedge(_ i: Int) -> NSBezierPath {
        let step = 360/CGFloat(max(1, actions.count))
        let mid = 90-CGFloat(i)*step
        let a = mid-step/2, b = mid+step/2
        let g = WheelGeometry.gap/2, ro = WheelGeometry.wedgeOuter, ri = WheelGeometry.wedgeInner
        let co = WheelGeometry.outerCorner, ci = WheelGeometry.innerCorner
        let deg: (CGFloat) -> CGFloat = { $0*180 / .pi }
        let c1 = point(ri+ci, a+deg(asin((g+ci)/(ri+ci))))
        let c2 = point(ro-co, a+deg(asin((g+co)/(ro-co))))
        let c3 = point(ro-co, b-deg(asin((g+co)/(ro-co))))
        let c4 = point(ri+ci, b-deg(asin((g+ci)/(ri+ci))))
        let t1i = point(ri, degrees(of: c1, around: center)), t1l = project(c1, angle: a, offset: g)
        let t2l = project(c2, angle: a, offset: g), t2o = point(ro, degrees(of: c2, around: center))
        let t3o = point(ro, degrees(of: c3, around: center)), t3l = project(c3, angle: b, offset: -g)
        let t4l = project(c4, angle: b, offset: -g), t4i = point(ri, degrees(of: c4, around: center))
        let path = CGMutablePath()
        path.move(to: t1l)
        path.addLine(to: t2l)
        addShortArc(path, around: c2, radius: co, from: t2l, to: t2o)
        path.addArc(center: center, radius: ro, startAngle: degrees(of: t2o, around: center) * .pi/180, endAngle: degrees(of: t3o, around: center) * .pi/180, clockwise: false)
        addShortArc(path, around: c3, radius: co, from: t3o, to: t3l)
        path.addLine(to: t4l)
        addShortArc(path, around: c4, radius: ci, from: t4l, to: t4i)
        path.addArc(center: center, radius: ri, startAngle: degrees(of: t4i, around: center) * .pi/180, endAngle: degrees(of: t1i, around: center) * .pi/180, clockwise: true)
        addShortArc(path, around: c1, radius: ci, from: t1i, to: t1l)
        path.closeSubpath()
        return NSBezierPath.from(path)
    }

    // MARK: Drawing
    private let ink = NSColor(srgbRed: 0.12, green: 0.09, blue: 0.07, alpha: 0.94)
    private let hoverInk = NSColor(srgbRed: 1, green: 0.85, blue: 0.74, alpha: 1)

    var centerLabel: String {
        let displayFiles = provisionalFiles.isEmpty ? files : provisionalFiles
        if let busyLabel { return busyLabel }
        if let hovered, actions.indices.contains(hovered) { return actions[hovered].label }
        if displayFiles.count > 1 { return "\(displayFiles.count) files" }
        if let file = displayFiles.first ?? file, let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        return isTools ? "TOOLS" : "CONVERT"
    }

    override func draw(_ dirtyRect: NSRect) {
        let R = WheelGeometry.radius
        let disk = NSBezierPath(ovalIn: NSRect(x: center.x-R, y: center.y-R, width: R*2, height: R*2))
        do {
            // A cool tint darkens the glass gaps, as in the recording. Without system
            // glass it stands in for the glass itself. Wedges and the centre keep the backdrop's colour.
            let band = NSBezierPath(); band.append(disk)
            let h = WheelGeometry.hole
            band.append(NSBezierPath(ovalIn: NSRect(x: center.x-h, y: center.y-h, width: h*2, height: h*2)))
            for i in actions.indices { band.append(wedge(i)) }
            band.windingRule = .evenOdd
            NSColor(srgbRed: 0.50, green: 0.52, blue: 0.58, alpha: hasGlassBackdrop ? 0.26 : 0.30).setFill(); band.fill()
        }
        // Bright rim on the outer glass edge.
        let rim = NSBezierPath(ovalIn: NSRect(x: center.x-R+0.6, y: center.y-R+0.6, width: R*2-1.2, height: R*2-1.2))
        NSColor.white.withAlphaComponent(0.55).setStroke(); rim.lineWidth = 1.2; rim.stroke()

        for (i, action) in actions.enumerated() {
            let path = wedge(i)
            let step = 360/CGFloat(actions.count)
            let mid = 90-CGFloat(i)*step
            if hovered == i {
                let g = NSGradient(colors: [NSColor(srgbRed: 1, green: 0.42, blue: 0.12, alpha: 0.97), NSColor(srgbRed: 0.90, green: 0.27, blue: 0.10, alpha: 0.97)])!
                g.draw(in: path, angle: mid)
                NSColor.white.withAlphaComponent(0.22).setStroke()
            } else {
                let top: CGFloat = hasGlassBackdrop ? 0.42 : 0.50
                let g = NSGradient(colors: [NSColor.white.withAlphaComponent(top), NSColor.white.withAlphaComponent(top-0.07)])!
                g.draw(in: path, angle: -90)
                NSColor.white.withAlphaComponent(0.6).setStroke()
            }
            path.lineWidth = 0.8; path.stroke()

            let color = (hovered == i ? hoverInk : ink).withAlphaComponent((hovered == i ? 1 : 0.94) * labelAlpha)
            let pos = point((WheelGeometry.wedgeInner+WheelGeometry.wedgeOuter)/2, mid)
            if let symbol = action.symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                if let tinted = icon.withSymbolConfiguration(cfg) {
                    let s = tinted.size
                    tinted.draw(in: NSRect(x: pos.x-s.width/2, y: pos.y+7-s.height/2, width: s.width, height: s.height))
                }
                draw(action.label, at: CGPoint(x: pos.x, y: pos.y-7.5), font: .systemFont(ofSize: 8, weight: .bold), kern: 0.45, color: color)
            } else {
                draw(action.label, at: pos, font: .systemFont(ofSize: 11, weight: .bold), kern: 0.2, color: color)
            }
        }

        // The well around the centre pill.
        let hole = WheelGeometry.hole
        let well = NSBezierPath(ovalIn: NSRect(x: center.x-hole, y: center.y-hole, width: hole*2, height: hole*2))
        NSColor.black.withAlphaComponent(hasGlassBackdrop ? 0.06 : 0.05).setFill(); well.fill()
        NSColor.white.withAlphaComponent(0.72).setStroke(); well.lineWidth = 1; well.stroke()

        let pillSize = WheelGeometry.pill
        let pillRect = NSRect(x: center.x-pillSize.width/2, y: center.y-pillSize.height/2, width: pillSize.width, height: pillSize.height)
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillSize.height/2, yRadius: pillSize.height/2)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.42), NSColor.white.withAlphaComponent(0.30)])!.draw(in: pill, angle: -90)
        NSColor.white.withAlphaComponent(0.55).setStroke(); pill.lineWidth = 0.8; pill.stroke()

        let label = centerLabel
        let pillInk = NSColor(srgbRed: 0.16, green: 0.12, blue: 0.09, alpha: 0.92)
        if let hovered, actions.indices.contains(hovered), busyLabel == nil {
            let tool = actions[hovered].symbol != nil
            draw(label, at: center, font: .systemFont(ofSize: tool ? 8 : 10, weight: .bold), kern: tool ? 0.45 : 0.2, color: pillInk, maxWidth: pillSize.width-10)
        } else {
            draw(label, at: center, font: .systemFont(ofSize: 11, weight: .semibold), kern: 0, color: pillInk, maxWidth: pillSize.width-10)
        }
    }

    private func draw(_ text: String, at p: CGPoint, font: NSFont, kern: CGFloat, color: NSColor, maxWidth: CGFloat = .greatestFiniteMagnitude) {
        var f = font
        var string = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color, .kern: kern])
        while string.size().width > maxWidth && f.pointSize > 6 {
            f = NSFont.systemFont(ofSize: f.pointSize-0.5, weight: font.fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .semibold)
            string = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color, .kern: kern])
        }
        let size = string.size()
        // Kerning adds trailing space after the last glyph; centre on the glyphs.
        string.draw(at: NSPoint(x: p.x-(size.width-kern)/2, y: p.y-size.height/2))
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
        guard let owner else { return false }; owner.execute(index, urls: owner.files); return true
    }
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(owner.wedge(index).bounds, to: nil))
    }
}

extension NSBezierPath {
    /// `NSBezierPath(cgPath:)` needs macOS 14; the app supports macOS 13.
    static func from(_ path: CGPath) -> NSBezierPath {
        let result = NSBezierPath()
        path.applyWithBlock { pointer in
            let e = pointer.pointee, p = e.points
            switch e.type {
            case .moveToPoint: result.move(to: p[0])
            case .addLineToPoint: result.line(to: p[0])
            case .addQuadCurveToPoint:
                let start = result.isEmpty ? p[0] : result.currentPoint
                result.curve(to: p[1], controlPoint1: CGPoint(x: start.x+2/3*(p[0].x-start.x), y: start.y+2/3*(p[0].y-start.y)), controlPoint2: CGPoint(x: p[1].x+2/3*(p[0].x-p[1].x), y: p[1].y+2/3*(p[0].y-p[1].y)))
            case .addCurveToPoint: result.curve(to: p[2], controlPoint1: p[0], controlPoint2: p[1])
            case .closeSubpath: result.close()
            @unknown default: break
            }
        }
        return result
    }
}
