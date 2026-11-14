import CoreGraphics
import Foundation

/// Drives the hold rule with fake time. No windows, no mouse, no Finder.
@main
struct HoldGestureTests {
    static func main() {
        let files = [URL(fileURLWithPath: "/tmp/a.png")]
        let p = CGPoint(x: 100, y: 100)
        let over = CGPoint(x: 140, y: 100)

        // A still press asks Finder after exactly two seconds, and only once.
        var g = HoldGesture()
        precondition(g.update(down: true, point: p, now: 0) == .none)
        precondition(g.update(down: true, point: CGPoint(x: 103, y: 100), now: 1) == .none, "3 pt of jitter still counts as still")
        precondition(g.update(down: true, point: p, now: 1.99) == .none, "Too early")
        precondition(g.update(down: true, point: p, now: 2) == .askFinder, "Two seconds of holding")
        precondition(g.update(down: true, point: p, now: 2.5) == .none, "Asks once per press")

        // Letting go before two seconds never opens, and the next press starts a fresh clock.
        g = HoldGesture()
        _ = g.update(down: true, point: p, now: 10)
        precondition(g.update(down: false, point: p, now: 11.5) == .none)
        precondition(g.update(down: true, point: p, now: 12) == .none)
        precondition(g.update(down: true, point: p, now: 13.9) == .none, "The old press's time must not count")
        precondition(g.update(down: true, point: p, now: 14) == .askFinder)

        // A press that moved without dragging a file (a window move, a selection box) never asks Finder.
        g = HoldGesture()
        _ = g.update(down: true, point: p, now: 0)
        _ = g.update(down: true, point: CGPoint(x: 130, y: 100), now: 0.3)
        precondition(g.update(down: true, point: CGPoint(x: 130, y: 100), now: 5) == .none, "Moved presses never ask Finder")

        // A drag opens with the dragged files once it pauses for two seconds.
        g = HoldGesture()
        _ = g.update(down: true, point: p, now: 0)
        _ = g.update(down: true, point: CGPoint(x: 110, y: 100), now: 0.2, drag: files)
        _ = g.update(down: true, point: CGPoint(x: 160, y: 120), now: 1)
        precondition(g.update(down: true, point: CGPoint(x: 161, y: 121), now: 2.9) == .none, "The pause began at 1 s")
        precondition(g.update(down: true, point: CGPoint(x: 161, y: 121), now: 3) == .openDrag(files))
        precondition(g.update(down: true, point: CGPoint(x: 161, y: 121), now: 6) == .none, "Opens once per press")

        // A moving drag never opens: normal Finder moves pass through.
        g = HoldGesture()
        _ = g.update(down: true, point: p, now: 0, drag: files)
        for step in 1...40 {
            let signal = g.update(down: true, point: CGPoint(x: 100 + Double(step) * 10, y: 100), now: Double(step) * 0.1)
            precondition(signal == .none, "A drag that keeps moving must not open the wheel")
        }

        // Once the held wheel is open, a later pause in the same press doesn't move it.
        g = HoldGesture()
        _ = g.update(down: true, point: p, now: 0)
        precondition(g.update(down: true, point: p, now: 2) == .askFinder)
        g.markOpened()
        _ = g.update(down: true, point: over, now: 2.5, drag: files)
        precondition(g.update(down: true, point: over, now: 5) == .none, "The open wheel must stay put")

        // When Finder had nothing (the press was in another app), a paused drag still opens.
        g = HoldGesture()
        _ = g.update(down: true, point: p, now: 0)
        precondition(g.update(down: true, point: p, now: 2) == .askFinder)
        _ = g.update(down: true, point: over, now: 2.5, drag: files)
        precondition(g.update(down: true, point: over, now: 4.5) == .openDrag(files))

        precondition(HoldGesture.delay == 2, "The hold is two seconds")
        print("PASS: 2-second still hold asks Finder once, early release and moved presses never open, paused drags open once, moving drags pass through.")
    }
}
