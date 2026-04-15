import AppKit
import Foundation

@MainActor
protocol GestureDelegate: AnyObject {
    func gestureDidUpdateCursor(_ pos: CGPoint, isDrawing: Bool)
    func gestureDidStartStroke(at pos: CGPoint)
    func gestureDidAppendPoint(_ pos: CGPoint)
    func gestureDidEndStroke()
}

/// Translates trackpad multi-touch state into drawing intent.
///
/// Invariants:
/// - 0 fingers → idle (pen holds last position, no ink)
/// - 1 finger  → drawing (delta-moved pen cursor is the pen tip)
/// - 2+ fingers → hovering (pen tracks primary finger delta, no ink)
///
/// The *primary* finger is the first one placed. When it lifts, any remaining
/// finger is promoted. Cursor moves by the primary finger's **delta** between
/// events — NOT by its absolute trackpad position — so lifting your hand and
/// putting it back anywhere on the trackpad resumes motion from where you left
/// off (mouse-like "pick up and reposition" behavior).
@MainActor
final class GestureStateMachine {
    /// - `pending`: one finger is down but no stroke yet — waiting for motion.
    /// - `drawing`: one finger moving = ink.
    /// - `hovering`: two+ fingers = move the pen, no ink. (Pan is handled
    ///    separately via the trackpad's scroll-wheel events; macOS reserves
    ///    3-finger swipes for system gestures so we don't try to capture them.)
    enum State { case idle, pending, drawing, hovering }

    /// How a trackpad-normalized delta maps to canvas-normalized delta.
    /// 1.0 = a full trackpad sweep covers the full canvas.
    var sensitivity: CGFloat = 1.0

    weak var delegate: GestureDelegate?
    private(set) var state: State = .idle
    private(set) var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// True when this event's delta *wanted* to push the cursor past the canvas
    /// edge (i.e. we had to clamp).
    private(set) var didClampCursorThisEvent: Bool = false

    /// True when this event applied a non-zero delta to the cursor. Used to
    /// confirm a pending single-finger into a real stroke.
    private(set) var didCursorMoveThisEvent: Bool = false

    private var primaryKey: Int?
    /// Last reported trackpad-normalized position of the primary finger.
    /// `nil` means "primary just (re)landed — do not apply a delta this event."
    private var lastPrimaryPos: CGPoint?

    func reset() {
        if state == .drawing { delegate?.gestureDidEndStroke() }
        state = .idle
        primaryKey = nil
        lastPrimaryPos = nil
        didClampCursorThisEvent = false
        didCursorMoveThisEvent = false
    }

    /// Jump the pen cursor to a specific normalized canvas position (used when
    /// entering canvas mode to align the pen with the current OS pointer
    /// position). Any in-progress stroke is ended, and delta tracking resets
    /// so the next touch event doesn't snap the cursor elsewhere.
    func setCursor(x: CGFloat, y: CGFloat) {
        if state == .drawing { delegate?.gestureDidEndStroke() }
        cursor = CGPoint(
            x: min(1, max(0, x)),
            y: min(1, max(0, y))
        )
        lastPrimaryPos = nil
        primaryKey = nil
        state = .idle
        delegate?.gestureDidUpdateCursor(cursor, isDrawing: false)
    }

    func update(touches: Set<NSTouch>) {
        // Only consider indirect (trackpad) touches; direct = touchscreen (rare on Mac).
        var fresh: [Int: CGPoint] = [:]
        for t in touches where t.type == .indirect {
            // Same finger → same NSTouch.identity across events. Use NSObject's
            // stable hash as the key.
            let key = (t.identity as? NSObject)?.hash ?? ObjectIdentifier(t).hashValue
            // NSTouch.normalizedPosition: origin (0,0) is bottom-left.
            // Flip Y so deltas line up with our top-left canvas coords.
            fresh[key] = CGPoint(
                x: t.normalizedPosition.x,
                y: 1.0 - t.normalizedPosition.y
            )
        }

        // --- Primary finger bookkeeping ---------------------------------------
        // If the primary lifted, pick a surviving finger as the new primary.
        // Suppress the delta on this event so the cursor doesn't jump to the
        // new finger's position.
        if let p = primaryKey, fresh[p] == nil {
            primaryKey = fresh.keys.sorted().first
            lastPrimaryPos = nil
        }
        // First time a finger lands (no primary yet): adopt it, no delta yet.
        if primaryKey == nil, let firstKey = fresh.keys.sorted().first {
            primaryKey = firstKey
            lastPrimaryPos = nil
        }

        // --- Accumulate cursor delta from the primary finger ------------------
        didClampCursorThisEvent = false
        didCursorMoveThisEvent = false
        if let p = primaryKey, let pos = fresh[p] {
            if let last = lastPrimaryPos {
                let dx = (pos.x - last.x) * sensitivity
                let dy = (pos.y - last.y) * sensitivity
                if dx != 0 || dy != 0 { didCursorMoveThisEvent = true }
                let rawX = cursor.x + dx
                let rawY = cursor.y + dy
                if rawX < 0 || rawX > 1 || rawY < 0 || rawY > 1 {
                    didClampCursorThisEvent = true
                }
                cursor.x = min(1, max(0, rawX))
                cursor.y = min(1, max(0, rawY))
            }
            lastPrimaryPos = pos
        } else {
            lastPrimaryPos = nil
        }

        // --- State transitions ------------------------------------------------
        let prev = state
        switch fresh.count {
        case 0:
            // All fingers lifted. Any pending-draw is discarded — no stroke.
            state = .idle
            if prev == .drawing { delegate?.gestureDidEndStroke() }
            delegate?.gestureDidUpdateCursor(cursor, isDrawing: false)
        case 1:
            switch prev {
            case .drawing:
                // Continue the in-progress stroke.
                state = .drawing
                delegate?.gestureDidAppendPoint(cursor)
            case .idle:
                // Fresh 0→1 transition: enter `pending`. We do NOT start a
                // stroke yet — we're waiting to see if this is a real single-
                // finger draw or the first finger of a 2-finger gesture
                // landing slightly before the second. Confirmed by movement.
                state = .pending
            case .pending:
                if didCursorMoveThisEvent {
                    // Confirmed: single finger is actually drawing.
                    state = .drawing
                    delegate?.gestureDidStartStroke(at: cursor)
                } else {
                    // Still held but hasn't moved — keep pending.
                    state = .pending
                }
            case .hovering:
                // 2→1 transition. Don't start a stroke — fingers rarely lift
                // in perfect sync, and a 2→1→0 lift-off would otherwise
                // produce a stray dot. Stay hovering until all fingers lift.
                state = .hovering
            }
            delegate?.gestureDidUpdateCursor(cursor, isDrawing: state == .drawing)
        default:
            // 2+ fingers: discard any pending draw; pen hovers (no ink).
            // 3-finger swipes are claimed by macOS for system gestures so we
            // deliberately don't try to use 3+ fingers for anything in-app.
            state = .hovering
            if prev == .drawing { delegate?.gestureDidEndStroke() }
            delegate?.gestureDidUpdateCursor(cursor, isDrawing: false)
        }
    }
}
