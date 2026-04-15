import SwiftUI
import AVFoundation
import Vision
import CoreImage
import AppKit

/// Sheet that shows a live webcam preview, runs document-segmentation on each
/// frame to highlight the detected page, and on "Capture" hands the extracted
/// line-art PNG back via `onCaptured`.
///
/// Camera access requires `NSCameraUsageDescription` in the app's Info.plist.
/// See `scripts/build-app.sh` for the bundle packaging.
struct CameraCaptureView: View {
    let onCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = CameraController()
    @State private var latestQuad: Quad?
    @State private var permissionDenied = false

    /// How long the current "hold steady" window has been going, 0..autoCaptureSeconds.
    @State private var holdProgress: Double = 0
    @State private var holdingSince: Date?

    /// Review state: when set, we're showing the last capture for user confirmation.
    @State private var reviewPNG: Data?
    @State private var reviewImage: NSImage?
    @State private var processing: Bool = false
    /// If a capture attempt fails we freeze auto-capture until this time so
    /// we don't retry-loop on every new stability event.
    @State private var retryCooldownUntil: Date?
    @State private var captureError: String?

    // Quality-over-speed: require a deliberate ~1.5s steady hold above a
    // fairly strict stability threshold. The pipeline we run on capture is
    // expensive (foreground mask + CILineOverlay), so we only want to kick
    // it off for a frame the user is genuinely satisfied with.
    private let autoCaptureSeconds: Double = 1.5
    private let autoCaptureThreshold: Double = 0.80

    var body: some View {
        VStack(spacing: 0) {
            if let img = reviewImage {
                reviewPane(img)
            } else {
                livePreviewPane
            }
            Divider()
            footer
        }
        .task {
            controller.onQuadDetected = { q in
                Task { @MainActor in latestQuad = q }
            }
            controller.onQuadLost = {
                Task { @MainActor in
                    latestQuad = nil
                    holdingSince = nil
                    holdProgress = 0
                }
            }
            let ok = await controller.start()
            if !ok { permissionDenied = true }
        }
        .onReceive(controller.$stabilityScore) { s in
            guard reviewImage == nil, !processing else { return }
            if let until = retryCooldownUntil, Date() < until {
                holdingSince = nil
                holdProgress = 0
                return
            }
            if s >= autoCaptureThreshold && latestQuad != nil {
                if holdingSince == nil { holdingSince = Date() }
                let elapsed = Date().timeIntervalSince(holdingSince ?? Date())
                holdProgress = min(1.0, elapsed / autoCaptureSeconds)
                if elapsed >= autoCaptureSeconds {
                    holdingSince = nil
                    holdProgress = 0
                    capture()
                }
            } else {
                holdingSince = nil
                holdProgress = 0
            }
        }
        .onDisappear { controller.stop() }
    }

    // MARK: Live preview with detection overlay + hold-steady ring

    private var livePreviewPane: some View {
        ZStack(alignment: .topLeading) {
            CameraPreview(layer: controller.previewLayer)
                .background(Color.black)
            if let quad = latestQuad {
                GeometryReader { geo in
                    QuadOverlay(
                        quad: quad,
                        imageSize: controller.lastImageSize ?? .zero,
                        viewSize: geo.size,
                        highlighted: holdProgress > 0
                    )
                }
            }
            if holdProgress > 0 {
                HoldRing(progress: holdProgress)
                    .frame(width: 72, height: 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .center)
                    .transition(.opacity)
            }
            if processing {
                Color.black.opacity(0.45)
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Processing…").foregroundStyle(.white).font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if permissionDenied {
                permissionOverlay
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var permissionOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text("Camera access denied")
            Text("Enable it in System Settings → Privacy & Security → Camera, then relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }

    // MARK: Review pane (Retake / Use this)

    private func reviewPane(_ nsImage: NSImage) -> some View {
        ZStack {
            Color(red: 0.985, green: 0.96, blue: 0.91)  // paper base behind lines
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(24)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: Footer (status + buttons)

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if reviewImage == nil {
                Button("Cancel") { dismiss() }
                Button {
                    capture()
                } label: {
                    Label("Capture now", systemImage: "camera.fill")
                }
                .keyboardShortcut(.return)
                .buttonStyle(.bordered)
                .disabled(!controller.isRunning || processing)
            } else {
                Button("Retake") {
                    reviewImage = nil
                    reviewPNG = nil
                    latestQuad = nil
                    Task { _ = await controller.start() }
                }
                Button {
                    if let png = reviewPNG {
                        onCaptured(png)
                        dismiss()
                    }
                } label: {
                    Label("Use this page", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }

    private var statusText: String {
        if permissionDenied { return "Camera disabled" }
        if let err = captureError { return err }
        if reviewImage != nil { return "Looks good? Pick Use this page or Retake." }
        if processing { return "Enhancing scan with Vision + Core Image…" }
        if !controller.isRunning { return "Starting camera…" }
        if latestQuad == nil {
            return "Hold up a drawing — detection will light up when it finds the page."
        }
        if holdProgress > 0 {
            let remaining = autoCaptureSeconds * (1 - holdProgress)
            return String(format: "Hold steady… capturing in %.1fs", remaining)
        }
        return "Page detected. Keep it still for auto-capture, or press ⏎."
    }

    // MARK: Capture flow

    private func capture() {
        guard !processing else { return }
        processing = true
        captureError = nil
        controller.captureFrame { cg in
            guard let cg = cg else {
                captureError = "Couldn't grab a frame. Try again."
                retryCooldownUntil = Date().addingTimeInterval(3)
                processing = false
                return
            }
            guard let png = VisionLineExtractor.extract(from: cg) else {
                captureError = "Scan processing failed. Adjust the lighting or angle and try again."
                retryCooldownUntil = Date().addingTimeInterval(3)
                processing = false
                return
            }
            reviewPNG = png
            reviewImage = NSImage(data: png)
            controller.stop()
            processing = false
        }
    }
}

// MARK: - Hold-steady progress ring

private struct HoldRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.4))
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 4)
                .padding(8)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.green,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(8)
                .animation(.linear(duration: 0.08), value: progress)
            Image(systemName: "camera.fill")
                .foregroundStyle(.white)
                .font(.system(size: 22))
        }
    }
}

// MARK: - Controller
//
// NOT @MainActor — the AVCapture sample-buffer delegate runs on a private
// serial queue, and any `MainActor.assumeIsolated` from there traps at
// runtime. Instead we keep nearly all internal state on that queue and
// dispatch explicitly to main only for the two @Published properties
// SwiftUI needs to observe.

final class CameraController: NSObject, ObservableObject,
                               AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer
    private let videoOutput = AVCaptureVideoDataOutput()
    /// Serial queue — delivers delegate events and serializes captureFrame().
    private let queue = DispatchQueue(label: "coloring-book.camera")

    @Published private(set) var isRunning = false
    @Published var lastImageSize: CGSize?

    /// 0.0 = moving, 1.0 = rock-still. The view watches this to auto-capture.
    @Published private(set) var stabilityScore: Double = 0.0

    /// Set once by the view during `.task`, read from the delegate. Effectively
    /// write-once, so no synchronization.
    var onQuadDetected: (Quad) -> Void = { _ in }
    var onQuadLost: () -> Void = { }

    // All accessed only on `queue` — no synchronization needed.
    private var latestBuffer: CVPixelBuffer?
    private var visionInFlight = false
    private var recentQuads: [Quad] = []       // up to last 8 detected quads
    private var lastDiag: Double = 1            // image diagonal, for normalizing
    private var framesWithoutQuad = 0

    override init() {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        previewLayer.videoGravity = .resizeAspect
    }

    /// Ask for camera permission (if needed), configure the session, start it.
    /// Returns false on permission denial / configuration failure.
    @MainActor
    func start() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = status == .authorized
        if status == .notDetermined {
            granted = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard granted else { return false }

        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            return false
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        // startRunning blocks; keep it off the main thread.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [session] in
                session.startRunning()
                cont.resume()
            }
        }
        let running = session.isRunning
        isRunning = running
        return running
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Snapshot the most recent frame as a CGImage; caller runs it through
    /// the full VisionLineExtractor pipeline.
    func captureFrame(completion: @escaping @Sendable (CGImage?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, let buffer = self.latestBuffer else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let ci = CIImage(cvPixelBuffer: buffer)
            let ctx = CIContext()
            let cg = ctx.createCGImage(ci, from: ci.extent)
            DispatchQueue.main.async { completion(cg) }
        }
    }

    // AVCaptureVideoDataOutputSampleBufferDelegate — runs on `queue`.
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Safe: we're always on `queue` here.
        self.latestBuffer = buffer

        let size = CGSize(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer)
        )
        DispatchQueue.main.async { [weak self] in
            self?.lastImageSize = size
        }

        // Throttle Vision to one request at a time.
        if self.visionInFlight { return }
        self.visionInFlight = true

        // Run document segmentation first; fall back to rectangle detection
        // with loose parameters. Document segmentation is more accurate when
        // it works, but it can fail when fingers occlude a corner — in that
        // case the rectangle detector still finds the paper.
        let segReq = VNDetectDocumentSegmentationRequest()

        let rectReq = VNDetectRectanglesRequest()
        rectReq.minimumAspectRatio = 0.3     // held at an angle → wide ratios
        rectReq.maximumAspectRatio = 1.6
        rectReq.minimumSize = 0.15           // page fills ≥15% of frame
        rectReq.minimumConfidence = 0.5
        rectReq.maximumObservations = 1
        rectReq.quadratureTolerance = 45     // forgive angled shots

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        _ = try? handler.perform([segReq, rectReq])

        let obs: VNRectangleObservation? =
            segReq.results?.first ?? rectReq.results?.first

        var detected: Quad?
        if let obs = obs {
            let w = Double(CVPixelBufferGetWidth(buffer))
            let h = Double(CVPixelBufferGetHeight(buffer))
            self.lastDiag = sqrt(w * w + h * h)
            func pt(_ n: CGPoint) -> CGPoint {
                CGPoint(x: n.x * w, y: n.y * h)
            }
            detected = Quad(
                topLeft: pt(obs.topLeft),
                topRight: pt(obs.topRight),
                bottomLeft: pt(obs.bottomLeft),
                bottomRight: pt(obs.bottomRight)
            )
        }
        self.visionInFlight = false

        if let q = detected {
            self.framesWithoutQuad = 0
            self.recentQuads.append(q)
            if self.recentQuads.count > 8 { self.recentQuads.removeFirst() }
            let score = self.computeStability()
            let callback = self.onQuadDetected
            DispatchQueue.main.async { [weak self] in
                self?.stabilityScore = score
                callback(q)
            }
        } else {
            self.framesWithoutQuad += 1
            if self.framesWithoutQuad >= 6 {
                // Quad has been missing for several frames — reset.
                self.recentQuads.removeAll()
                let cb = self.onQuadLost
                DispatchQueue.main.async { [weak self] in
                    self?.stabilityScore = 0
                    cb()
                }
            }
        }
    }

    /// Stability metric tolerant to finger-at-the-edges jitter. We look at
    /// the quad's *center* and *size* — both of which stay stable even when
    /// a corner wiggles because of an occluding finger. Corner-only stability
    /// was too strict and rejected real "holding steady" motion.
    private func computeStability() -> Double {
        guard recentQuads.count >= 4 else { return 0 }

        let centers = recentQuads.map { q -> CGPoint in
            CGPoint(
                x: (q.topLeft.x + q.topRight.x + q.bottomLeft.x + q.bottomRight.x) / 4,
                y: (q.topLeft.y + q.topRight.y + q.bottomLeft.y + q.bottomRight.y) / 4
            )
        }
        var maxCenterMove: Double = 0
        for i in 1 ..< centers.count {
            maxCenterMove = max(maxCenterMove, dist(centers[i - 1], centers[i]))
        }
        let centerNorm = maxCenterMove / (lastDiag * 0.02)   // 2% diag = unstable
        let centerStability = max(0, min(1, 1 - centerNorm))

        // Size stability via main diagonal length — if the quad shrinks /
        // grows, the camera is moving toward / away from the page.
        let diags = recentQuads.map { q -> Double in
            dist(q.topLeft, q.bottomRight)
        }
        let minD = diags.min() ?? 1
        let maxD = diags.max() ?? 1
        let sizeRatio = maxD > 0 ? minD / maxD : 0    // 1.0 = identical size

        return centerStability * sizeRatio
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return Double(sqrt(dx * dx + dy * dy))
    }
}

// MARK: - Preview

private struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer = CALayer()
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(layer)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        layer.frame = nsView.bounds
    }
}

// MARK: - Overlay

private struct QuadOverlay: View {
    let quad: Quad
    let imageSize: CGSize
    let viewSize: CGSize
    var highlighted: Bool = false

    var body: some View {
        Path { p in
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            // AVCaptureVideoPreviewLayer with .resizeAspect letterboxes the
            // image; compute the rendered rect so the quad overlays align.
            let imgAspect = imageSize.width / imageSize.height
            let viewAspect = viewSize.width / viewSize.height
            var drawRect = CGRect(origin: .zero, size: viewSize)
            if imgAspect > viewAspect {
                let h = viewSize.width / imgAspect
                drawRect = CGRect(x: 0, y: (viewSize.height - h) / 2,
                                  width: viewSize.width, height: h)
            } else {
                let w = viewSize.height * imgAspect
                drawRect = CGRect(x: (viewSize.width - w) / 2, y: 0,
                                  width: w, height: viewSize.height)
            }

            func map(_ pt: CGPoint) -> CGPoint {
                // Vision returns image-space coords (origin bottom-left, y-up).
                // AppKit overlay also has y-up if the view isn't flipped — but
                // SwiftUI Paths use top-left y-down. Flip Y.
                let nx = pt.x / imageSize.width
                let ny = 1.0 - pt.y / imageSize.height
                return CGPoint(
                    x: drawRect.origin.x + nx * drawRect.width,
                    y: drawRect.origin.y + ny * drawRect.height
                )
            }
            let tl = map(quad.topLeft)
            let tr = map(quad.topRight)
            let bl = map(quad.bottomLeft)
            let br = map(quad.bottomRight)
            p.move(to: tl)
            p.addLine(to: tr)
            p.addLine(to: br)
            p.addLine(to: bl)
            p.closeSubpath()
        }
        .stroke(
            highlighted ? Color.green : Color.yellow.opacity(0.85),
            style: StrokeStyle(lineWidth: highlighted ? 3 : 2,
                               lineJoin: .round)
        )
        .shadow(color: .black.opacity(0.5), radius: 2)
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}
