import AppKit

/// A non-destructive editor whose annotations are stored in source-image pixels.
/// Both the view and the exported bitmap use a bottom-left coordinate origin.
final class ODAnnotationCanvas: NSView {
    enum Tool: String {
        case pen, rectangle, arrow, text, redact
    }

    var tool: Tool = .pen {
        didSet {
            if tool != oldValue {
                activeAnnotation = nil
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var inkColor: NSColor = .systemOrange
    /// Stroke thickness in original-image pixels, independent of preview scale.
    var strokeWidth: CGFloat = 4
    /// Text is inserted at the next click, with its top-left corner at the click.
    var textValue: String = "Text"
    /// Called after an annotation is committed, undone, or cleared.
    var onChange: (() -> Void)?
    var count: Int { annotations.count }

    private struct Annotation {
        let tool: Tool
        var points: [CGPoint]
        let color: NSColor
        let width: CGFloat
        let text: String
    }

    private let originalImage: CGImage
    private var annotations: [Annotation] = []
    private var activeAnnotation: Annotation?
    private let previewInset: CGFloat = 10

    init(image: CGImage) {
        originalImage = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image annotation canvas")
        setAccessibilityIdentifier("editor.annotation.canvas")
        setAccessibilityHelp("Drag to draw. Select Text and click to insert text.")
    }

    @available(*, unavailable, message: "Use init(image:)")
    required init?(coder: NSCoder) {
        fatalError("Use init(image:)")
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !imageRect.isEmpty {
            addCursorRect(imageRect, cursor: tool == .text ? .iBeam : .crosshair)
        }
    }

    func undo() {
        if activeAnnotation != nil {
            activeAnnotation = nil
            needsDisplay = true
            return
        }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        didChangeAnnotations()
    }

    func clear() {
        activeAnnotation = nil
        needsDisplay = true
        guard !annotations.isEmpty else { return }
        annotations.removeAll()
        didChangeAnnotations()
    }

    /// Returns a flattened image at the original pixel dimensions. Redactions
    /// replace pixels with opaque black; the original CGImage is never modified.
    func renderedImage() -> CGImage? {
        guard !annotations.isEmpty || activeAnnotation != nil else {
            return originalImage
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil, width: originalImage.width, height: originalImage.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        drawImageAndAnnotations(in: context)
        return context.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.97, alpha: 0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let rect = imageRect
        guard !rect.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / sourceBounds.width
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        drawImageAndAnnotations(in: context)

        // This affordance is drawn only in the preview, never into the export.
        if let active = activeAnnotation,
           active.tool == .rectangle || active.tool == .redact {
            let selection = active.tool == .redact
                ? redactionRect(for: active) : dragRect(for: active)
            guard !selection.isEmpty else { return }
            context.clip(to: sourceBounds)
            context.setStrokeColor(NSColor.systemOrange.cgColor)
            context.setLineWidth(1.5 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale])
            context.stroke(selection)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = sourcePoint(for: event, clampToImage: false) else { return }
        window?.makeFirstResponder(self)
        activeAnnotation = nil
        let width = strokeWidth.isFinite ? max(0.5, strokeWidth) : 4
        let annotation = Annotation(
            tool: tool, points: [point],
            color: inkColor.usingColorSpace(.sRGB) ?? .systemOrange,
            width: width, text: textValue
        )
        if tool == .text {
            guard !textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            annotations.append(annotation)
            didChangeAnnotations()
        } else {
            activeAnnotation = annotation
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateActiveAnnotation(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeAnnotation != nil else { return }
        updateActiveAnnotation(with: event)
        guard let annotation = activeAnnotation else { return }
        activeAnnotation = nil
        needsDisplay = true
        guard isDrawable(annotation) else { return }
        annotations.append(annotation)
        didChangeAnnotations()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, activeAnnotation != nil {
            activeAnnotation = nil
            needsDisplay = true
        } else if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "z" {
            undo()
        } else {
            super.keyDown(with: event)
        }
    }

    private var sourceBounds: CGRect {
        CGRect(x: 0, y: 0, width: originalImage.width, height: originalImage.height)
    }

    private var imageRect: CGRect {
        guard bounds.width > previewInset * 2, bounds.height > previewInset * 2 else { return .zero }
        let available = bounds.insetBy(dx: previewInset, dy: previewInset)
        let scale = min(available.width / sourceBounds.width, available.height / sourceBounds.height)
        let size = CGSize(width: sourceBounds.width * scale, height: sourceBounds.height * scale)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func sourcePoint(for event: NSEvent, clampToImage: Bool) -> CGPoint? {
        let rect = imageRect
        guard !rect.isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard clampToImage || rect.contains(point) else { return nil }
        return CGPoint(
            x: min(sourceBounds.width, max(0, (point.x - rect.minX) / rect.width * sourceBounds.width)),
            y: min(sourceBounds.height, max(0, (point.y - rect.minY) / rect.height * sourceBounds.height))
        )
    }

    private func updateActiveAnnotation(with event: NSEvent) {
        guard let first = activeAnnotation?.points.first,
              let point = sourcePoint(for: event, clampToImage: true) else { return }
        if activeAnnotation?.tool == .pen {
            if activeAnnotation?.points.last != point {
                activeAnnotation?.points.append(point)
            }
        } else {
            activeAnnotation?.points = [first, point]
        }
        needsDisplay = true
    }

    private func didChangeAnnotations() {
        needsDisplay = true
        onChange?()
    }

    private func dragRect(for annotation: Annotation) -> CGRect {
        guard let first = annotation.points.first, let last = annotation.points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    private func redactionRect(for annotation: Annotation) -> CGRect {
        let rect = dragRect(for: annotation)
        guard !rect.isEmpty else { return .zero }
        // Expand fractional edges so every touched source pixel is covered.
        return CGRect(x: floor(rect.minX), y: floor(rect.minY),
                      width: ceil(rect.maxX) - floor(rect.minX),
                      height: ceil(rect.maxY) - floor(rect.minY)).intersection(sourceBounds)
    }

    private func isDrawable(_ annotation: Annotation) -> Bool {
        switch annotation.tool {
        case .pen, .text:
            return !annotation.points.isEmpty
        case .rectangle, .redact:
            return !dragRect(for: annotation).isEmpty
        case .arrow:
            guard let first = annotation.points.first, let last = annotation.points.last else { return false }
            return hypot(last.x - first.x, last.y - first.y) > 0.01
        }
    }

    private func drawImageAndAnnotations(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: sourceBounds)
        context.setAlpha(1)
        context.setBlendMode(.normal)
        context.interpolationQuality = .high
        context.draw(originalImage, in: sourceBounds)
        var visible = annotations
        if let active = activeAnnotation, isDrawable(active) { visible.append(active) }
        for annotation in visible where annotation.tool != .redact {
            draw(annotation, in: context)
        }
        // Redaction masks stay opaque even if other marks are added afterward.
        for annotation in visible where annotation.tool == .redact {
            draw(annotation, in: context)
        }
    }

    private func draw(_ annotation: Annotation, in context: CGContext) {
        guard let first = annotation.points.first else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(annotation.width)
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)

        switch annotation.tool {
        case .pen:
            if annotation.points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - annotation.width / 2,
                                               y: first.y - annotation.width / 2,
                                               width: annotation.width, height: annotation.width))
            } else {
                context.beginPath()
                context.addLines(between: annotation.points)
                context.strokePath()
            }
        case .rectangle:
            context.stroke(dragRect(for: annotation))
        case .arrow:
            guard let tip = annotation.points.last else { return }
            let length = hypot(tip.x - first.x, tip.y - first.y)
            guard length > 0.01 else { return }
            let direction = CGPoint(x: (tip.x - first.x) / length, y: (tip.y - first.y) / length)
            let headLength = min(length * 0.6, max(12, annotation.width * 4))
            let halfWidth = headLength * 0.45
            let base = CGPoint(x: tip.x - direction.x * headLength, y: tip.y - direction.y * headLength)
            context.beginPath()
            context.move(to: first)
            context.addLine(to: base)
            context.strokePath()
            context.beginPath()
            context.move(to: tip)
            context.addLine(to: CGPoint(x: base.x - direction.y * halfWidth, y: base.y + direction.x * halfWidth))
            context.addLine(to: CGPoint(x: base.x + direction.y * halfWidth, y: base.y - direction.x * halfWidth))
            context.closePath()
            context.fillPath()
        case .text:
            drawText(annotation, at: first, in: context)
        case .redact:
            context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false)
            context.setBlendMode(.copy)
            context.setAlpha(1)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(redactionRect(for: annotation))
        }
    }

    private func drawText(_ annotation: Annotation, at point: CGPoint, in context: CGContext) {
        let width = sourceBounds.maxX - point.x
        guard width > 0, point.y > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: annotation.text, attributes: [
            .font: NSFont.systemFont(ofSize: max(18, annotation.width * 5), weight: .semibold),
            .foregroundColor: annotation.color,
            .paragraphStyle: paragraph
        ])
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let measured = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options)
        let height = ceil(measured.height)
        // Keep the clicked top edge fixed; image clipping handles overflow below.
        text.draw(with: CGRect(x: point.x, y: point.y - height, width: width, height: height), options: options)
    }
}
