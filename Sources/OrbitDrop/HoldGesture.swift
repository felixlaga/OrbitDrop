import CoreGraphics
import Foundation

/// Decides when a mouse press opens the wheel. One rule covers both ways in:
/// the button stays down and the pointer stays still for `delay` seconds.
///
/// - A press that never moved asks Finder which file is held (`askFinder`).
///   A press that moved without dragging a file is a window move or a selection box, so it never asks.
/// - A press that turned into a file drag opens with the dragged files once the drag pauses (`openDrag`).
///
/// Pure state, so tests can drive it with fake time.
struct HoldGesture {
    enum Signal: Equatable { case none, askFinder, openDrag([URL]) }

    static let delay: CFAbsoluteTime = 2
    /// Pointer movement, in points, that still counts as holding still.
    static let tolerance: CGFloat = 4

    private var pressed = false
    private var pressPoint = CGPoint.zero
    private var restPoint = CGPoint.zero
    private var restSince: CFAbsoluteTime = 0
    private var movedSincePress = false
    private var dragFiles: [URL] = []
    private var askedFinder = false
    private var opened = false

    /// Call on every poll. `drag` carries the openable files of a drag that started during this press.
    mutating func update(down: Bool, point: CGPoint, now: CFAbsoluteTime, drag: [URL]? = nil) -> Signal {
        guard down else { pressed = false; return .none }
        if !pressed {
            pressed = true; pressPoint = point; restPoint = point; restSince = now
            movedSincePress = false; dragFiles = []; askedFinder = false; opened = false
        }
        if let drag, !drag.isEmpty, dragFiles.isEmpty { dragFiles = drag }
        if hypot(point.x-restPoint.x, point.y-restPoint.y) > Self.tolerance { restPoint = point; restSince = now }
        if hypot(point.x-pressPoint.x, point.y-pressPoint.y) > Self.tolerance { movedSincePress = true }
        guard !opened, now-restSince >= Self.delay else { return .none }
        if !dragFiles.isEmpty { opened = true; return .openDrag(dragFiles) }
        if !movedSincePress && !askedFinder { askedFinder = true; return .askFinder }
        return .none
    }

    /// The wheel opened for this press, so no later pause in the same press may move it.
    mutating func markOpened() { opened = true }
}
