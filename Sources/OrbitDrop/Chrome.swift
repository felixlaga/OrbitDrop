import AppKit

/// Glass backdrop shaped as a rounded rectangle (a circle when the radius is half the side).
/// macOS 26 uses the system Liquid Glass; older systems get a masked blur, which
/// keeps the blur inside the shape instead of filling the whole window rectangle.
func makeGlassBackdrop(frame: NSRect, cornerRadius: CGFloat, clear: Bool = false) -> NSView {
    if #available(macOS 26.0, *), UserDefaults.standard.object(forKey: "useSystemGlass") as? Bool != false {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = cornerRadius
        glass.style = clear ? .clear : .regular
        return glass
    }
    let blur = NSVisualEffectView(frame: frame)
    blur.material = .popover
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.maskImage = NSImage(size: frame.size, flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        return true
    }
    return blur
}

var usesSystemGlass: Bool {
    if #available(macOS 26.0, *) { return UserDefaults.standard.object(forKey: "useSystemGlass") as? Bool != false }
    return false
}

/// The small circular close button used by the toast and editor title bars.
final class CloseCircleButton: NSButton {
    var handler: (() -> Void)?
    init(frame: NSRect, identifier: String, label: String) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        target = self
        action = #selector(invoke)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.black.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill(); circle.fill()
        let size: CGFloat = bounds.width * 0.42
        if let mark = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.labelColor.withAlphaComponent(0.62)]))) {
            let s = mark.size
            mark.draw(in: NSRect(x: bounds.midX-s.width/2, y: bounds.midY-s.height/2, width: s.width, height: s.height))
        }
    }
}

/// “Converting to JPG — 1 of 1 saved” card that appears where a file was dropped.
final class ProgressToast: NSObject {
    static let size = NSSize(width: 312, height: 93)
    let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = ProgressBar(frame: NSRect(x: 16.5, y: 17, width: 279, height: 4))
    private var shownAt = CFAbsoluteTimeGetCurrent()
    var onCancel: (() -> Void)?

    init(title text: String, total: Int, at point: NSPoint) {
        let size = Self.size
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.addSubview(makeGlassBackdrop(frame: root.bounds, cornerRadius: 22, clear: true))
        let tint = NSView(frame: root.bounds); tint.wantsLayer = true
        tint.layer?.cornerRadius = 22; tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        root.addSubview(tint)
        let close = CloseCircleButton(frame: NSRect(x: 13.5, y: size.height-33, width: 20, height: 20), identifier: "toast.cancel", label: "Cancel")
        close.handler = { [weak self] in self?.onCancel?(); self?.dismiss() }
        root.addSubview(close)
        title.stringValue = text
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.labelColor.withAlphaComponent(0.6)
        title.frame = NSRect(x: 43, y: size.height-32, width: size.width-60, height: 18)
        root.addSubview(title)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor.labelColor.withAlphaComponent(0.5)
        detail.frame = NSRect(x: 16.5, y: size.height-62, width: size.width-33, height: 15)
        root.addSubview(detail)
        root.addSubview(bar)
        panel.contentView = root
        update(saved: 0, total: total)
        let frame = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = max(frame.minX+8, min(point.x-size.width/2, frame.maxX-size.width-8))
        let y = max(frame.minY+8, min(point.y-size.height/2, frame.maxY-size.height-8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        shownAt = CFAbsoluteTimeGetCurrent()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if let layer = panel.contentView?.layer {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.35; grow.toValue = 1; grow.duration = 0.16
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: Self.size.width/2, y: Self.size.height/2)
            layer.add(grow, forKey: "grow")
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func update(saved: Int, total: Int) {
        detail.stringValue = "\(saved) of \(total) saved"
        bar.fraction = total == 0 ? 0 : CGFloat(saved)/CGFloat(total)
    }

    /// Leaves the finished card up just long enough to read, then fades it.
    func finish() {
        let wait = max(0.25, 0.55-(CFAbsoluteTimeGetCurrent()-shownAt))
        DispatchQueue.main.asyncAfter(deadline: .now()+wait) { self.dismiss() }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) { [panel] in panel.orderOut(nil) }
    }
}

private final class ProgressBar: NSView {
    var fraction: CGFloat = 0 {
        didSet { shown = max(shown, 0.06); animateTo(fraction) }
    }
    private var shown: CGFloat = 0
    private var timer: Timer?
    private func animateTo(_ target: CGFloat) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.shown += (max(target, 0.06)-self.shown)*0.25
            if abs(self.shown-max(target, 0.06)) < 0.002 { self.shown = max(target, 0.06); t.invalidate() }
            self.needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height/2
        NSColor.black.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width*shown), height: bounds.height)
        orbitAccent.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}
