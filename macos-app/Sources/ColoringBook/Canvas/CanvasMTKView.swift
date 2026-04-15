import AppKit
import MetalKit
import CoreGraphics

/// NSView subclass that owns the Metal view *and* captures trackpad multi-touch.
///
/// Drawing happens only while **canvas mode** is on. Canvas mode is a global
/// app flag (owned by `SessionModel`, toggled by `Space`). When it's on the OS
/// pointer is hidden inside this view (transparent cursor rect) and frozen
/// (`CGAssociateMouseAndMouseCursorPosition(0)`) so only the pen responds to
/// trackpad input. When it's off the trackpad drives the OS pointer normally.
final class CanvasMTKView: MTKView {
    let gestureMachine = GestureStateMachine()

    /// Invoked when the user presses Space. Wired up by the coordinator to
    /// `SessionModel.toggleCanvasMode()`.
    var onToggleCanvasMode: (() -> Void)?

    /// Pinch delta from `NSEvent.magnify` plus the anchor the pinch started
    /// over (canvas-view UV, y-down). The caller multiplies zoom by
    /// (1 + delta) and shifts pan so the anchor stays under the fingers.
    var onPinchMagnification: ((CGFloat, CGPoint) -> Void)?

    /// 2-finger scroll deltas (and the momentum tail), expressed as a fraction
    /// of the view's bounds. Caller converts to canvas-normalized pan units.
    var onScrollPan: ((CGFloat, CGFloat) -> Void)?

    /// Cmd+0: reset zoom to 100%.
    var onResetZoom: (() -> Void)?

    private var isPinching = false
    /// Anchor (canvas-view UV, y-down) where the current pinch started — the
    /// point we keep stationary under the user's fingers as they zoom.
    private var pinchAnchorUV = CGPoint(x: 0.5, y: 0.5)

    /// Driven by the coordinator from `SessionModel.isInCanvasMode`. The setter
    /// is responsible for flipping disassociation, the cursor rect, and warping
    /// the OS pointer to/from the pen's position on the boundary.
    var isInCanvasMode: Bool = true {
        didSet {
            guard isInCanvasMode != oldValue else { return }
            if isInCanvasMode {
                enterCanvasMode()
            } else {
                exitCanvasMode()
            }
        }
    }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }
    required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false

        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)

        let nc = NotificationCenter.default
        nc.removeObserver(self)
        if let win = window {
            nc.addObserver(self, selector: #selector(windowLostFocus),
                           name: NSWindow.didResignKeyNotification, object: win)
            nc.addObserver(self, selector: #selector(windowLostFocus),
                           name: NSWindow.willCloseNotification, object: win)
            nc.addObserver(self, selector: #selector(windowGainedFocus),
                           name: NSWindow.didBecomeKeyNotification, object: win)
        }
        nc.addObserver(self, selector: #selector(appResigned),
                       name: NSApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appResigned),
                       name: NSApplication.willTerminateNotification, object: nil)

        // Apply current mode state now that we have a window.
        if isInCanvasMode { enterCanvasMode() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Paranoia: never leave the trackpad disassociated if we disappear.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    @objc private func windowLostFocus() {
        // Re-associate for safety while backgrounded; don't change app mode.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    @objc private func windowGainedFocus() {
        if isInCanvasMode {
            CGAssociateMouseAndMouseCursorPosition(0)
        }
    }
    @objc private func appResigned() {
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Cursor rect (hides OS pointer inside the canvas while canvas mode on)

    override func resetCursorRects() {
        super.resetCursorRects()
        if isInCanvasMode {
            addCursorRect(bounds, cursor: Self.invisibleCursor)
        }
    }

    private static let invisibleCursor: NSCursor = {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: 8, y: 8))
    }()

    // MARK: Mode transitions

    private func enterCanvasMode() {
        // Align pen with the OS pointer's position if it's currently over the
        // canvas — the user's mental model is "pen picks up where the pointer
        // is." If the pointer is elsewhere (side panel, outside window), leave
        // the pen where it was.
        if let normalized = normalizedMousePositionIfOverCanvas() {
            gestureMachine.setCursor(x: normalized.x, y: normalized.y)
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        window?.invalidateCursorRects(for: self)
    }

    private func exitCanvasMode() {
        // Cancel any in-progress stroke, then warp the OS pointer to where
        // the pen was. The cursor rect is removed, so the pointer becomes
        // visible on the canvas at that spot.
        gestureMachine.reset()
        CGAssociateMouseAndMouseCursorPosition(1)
        warpOSCursor(toNormalizedCanvas: gestureMachine.cursor)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Geometry helpers

    /// Current OS pointer position expressed as normalized canvas coords
    /// (0..1, y-down to match our canvas convention). Returns nil if the
    /// pointer is outside the canvas view.
    private func normalizedMousePositionIfOverCanvas() -> CGPoint? {
        guard let window = self.window else { return nil }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = self.convert(windowPoint, from: nil)
        guard bounds.contains(viewPoint), bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        // NSView default: y=0 is bottom. Canvas y=0 is top. Flip.
        let nx = viewPoint.x / bounds.width
        let ny = 1.0 - (viewPoint.y / bounds.height)
        return CGPoint(x: nx, y: ny)
    }

    private func warpOSCursor(toNormalizedCanvas pen: CGPoint) {
        guard let window = self.window else { return }
        let viewPoint = NSPoint(
            x: pen.x * bounds.width,
            y: (1.0 - pen.y) * bounds.height  // flip back to y-up
        )
        let windowPoint = self.convert(viewPoint, to: nil)
        let appKitScreenPoint = window.convertPoint(toScreen: windowPoint)
        // AppKit screen coords (y-up, origin bottom-left of primary display)
        // → CG screen coords (y-down, origin top-left of primary display).
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let cgPoint = CGPoint(
            x: appKitScreenPoint.x,
            y: primaryHeight - appKitScreenPoint.y
        )
        CGWarpMouseCursorPosition(cgPoint)
        // Clear the 250ms suppression that CGWarp imposes on trackpad motion.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if !event.isARepeat, event.charactersIgnoringModifiers == " " {
            onToggleCanvasMode?()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "0" {
            onResetZoom?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Scroll → pan (pointer mode only)
    //
    // In pointer mode the system cursor moves with the trackpad and the user
    // can pinch (zoom) and 2-finger drag (scroll). We map scroll into a
    // canvas pan, with macOS providing the momentum tail for free → Google-
    // Maps style smooth inertia.
    //
    // In canvas mode 2-finger drag belongs to the pen (move-pen-no-ink), so
    // we deliberately let the event bubble up rather than panning.
    override func scrollWheel(with event: NSEvent) {
        guard !isInCanvasMode else {
            super.scrollWheel(with: event)
            return
        }
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        let dx = event.scrollingDeltaX / w
        let dy = event.scrollingDeltaY / h
        if dx == 0 && dy == 0 { return }
        onScrollPan?(dx, dy)
    }

    // MARK: Pinch-to-zoom

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            isPinching = true
            // Any in-progress hover-delta accumulation is now stale. End any
            // stroke and clear delta tracking so the pen doesn't jump when
            // the pinch ends.
            gestureMachine.reset()
            // Lock the anchor for this pinch to where the cursor sits. NSView
            // is y-up; our canvas / shader UV is y-down, so flip Y.
            let inView = convert(event.locationInWindow, from: nil)
            let w = max(bounds.width, 1)
            let h = max(bounds.height, 1)
            pinchAnchorUV = CGPoint(
                x: max(0, min(1, inView.x / w)),
                y: max(0, min(1, 1 - inView.y / h))
            )
        case .changed:
            onPinchMagnification?(event.magnification, pinchAnchorUV)
        case .ended, .cancelled:
            isPinching = false
        default:
            break
        }
    }

    // MARK: Touch events

    private func handleTouches(_ event: NSEvent) {
        // In non-canvas mode, the trackpad controls the OS pointer. Don't
        // interpret touches as drawing at all.
        guard isInCanvasMode else { return }
        // While a pinch gesture is active, the two-finger motion belongs to
        // zoom, not hover-pen — skip gesture updates so the pen doesn't
        // slide with the pinching fingers.
        if isPinching { return }
        let t = event.touches(matching: .touching, in: self)
        gestureMachine.update(touches: t)
    }

    override func touchesBegan(with event: NSEvent) { handleTouches(event) }
    override func touchesMoved(with event: NSEvent) { handleTouches(event) }
    override func touchesEnded(with event: NSEvent) { handleTouches(event) }
    override func touchesCancelled(with event: NSEvent) {
        guard isInCanvasMode else { return }
        gestureMachine.update(touches: [])
    }
}
