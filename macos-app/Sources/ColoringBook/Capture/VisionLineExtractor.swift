import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// High-quality camera-to-line-art pipeline.
///
/// Stages, in order (each one can fail / fall through to the next):
///
/// 1. **`VNGenerateForegroundInstanceMaskRequest` (macOS 14+)** — isolates the
///    "main subject" (held paper + hands) from background clutter. Feeding a
///    masked image to the document detector dramatically improves recognition
///    when fingers or uneven background would otherwise confuse it.
///
/// 2. **Document detection** — `VNDetectDocumentSegmentationRequest` (ML-based)
///    primary; `VNDetectRectanglesRequest` with loose parameters as fallback.
///
/// 3. **Perspective correction** — `CIPerspectiveCorrection` on the ORIGINAL
///    (un-masked, un-cropped) image, keyed on the detected quad. This
///    flattens the page to a rectangle.
///
/// 4. **Pre-enhancement** — desaturate, bump contrast, unsharp-mask so
///    pencil/pen strokes are crisp before edge extraction.
///
/// 5. **Line extraction** — Apple's `CILineOverlay` filter. Purpose-built for
///    photo→line-drawing conversion; tuned here for paper sketches.
///
/// 6. **Colorize** — map the filter's black-on-white output to
///    black-on-transparent so it composites as an overlay on our paper.
///
/// 7. **Encode** as PNG, downsized to ≤1400 px so the WebSocket payload stays
///    under a few hundred KB.
enum VisionLineExtractor {

    static func extract(from cg: CGImage) -> Data? {
        extractHighQuality(from: CIImage(cgImage: cg))
    }

    /// Load a *pre-made* coloring page (a clean PNG or JPG you downloaded —
    /// not a photo of a sketch). Skips all document/perspective processing;
    /// just desaturates and converts the background to transparent so the
    /// page composites cleanly over our paper.
    static func loadColoringPage(from url: URL) -> Data? {
        guard let ns = NSImage(contentsOf: url),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let prepared = whiteToAlpha(CIImage(cgImage: cg))
        return pngData(from: prepared)
    }

    /// Convert a clean line-art image (JPG/PNG, with or without alpha) into
    /// black-on-transparent using a single linear formula that works for all
    /// four input cases:
    ///
    ///     alpha_out = A_in - luma(RGB_in)       (with premultiplied RGB)
    ///
    /// - Opaque black       (A=1, RGB=0)  → alpha 1          (opaque black line)
    /// - Opaque white       (A=1, RGB=1)  → alpha 0          (transparent paper)
    /// - Already transparent(A=0, RGB=0)  → alpha 0          (stays transparent)
    /// - Anti-aliased edge  (A=1, RGB=.5) → alpha .5         (soft black edge)
    static func whiteToAlpha(_ ci: CIImage) -> CIImage {
        // Desaturate (render colored outlines as black) and bump contrast a
        // touch so gray lines on white paper register opaque.
        let gray = ci.applyingFilter("CIColorControls", parameters: [
            "inputSaturation": 0.0,
            "inputBrightness": 0.0,
            "inputContrast": 1.2,
        ])
        // Premultiply so RGB reflects what's visible even at partial alpha.
        let premul = gray.premultiplyingAlpha()
        let finite = premul.extent

        // No bias on the alpha vector → no infinite-extent issue.
        let out = premul.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: -0.299, y: -0.587, z: -0.114, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        return out.cropped(to: finite)
    }

    static func extractHighQuality(from ci: CIImage) -> Data? {
        // 1) Isolate foreground subject so the detector isn't confused by
        //    cluttered background. Fall back to the raw image if the model
        //    can't find a subject (unlikely under normal lighting).
        let maskedForDetection = isolateSubject(ci) ?? ci

        // 2) Detect the page quad. Try masked image first, raw as fallback.
        let quad = detectDocument(in: maskedForDetection)
                ?? detectDocument(in: ci)

        // 3) Perspective-correct the ORIGINAL image (not the masked one —
        //    masking would dim the paper content). If no quad, pass through.
        let rectified: CIImage
        if let q = quad, let corrected = perspectiveCorrect(ci, quad: q) {
            rectified = corrected
        } else {
            rectified = ci
        }

        // 4–6) Enhance + extract lines + make transparent.
        let lineArt = lineOverlayPipeline(rectified)

        // 7) Encode.
        return pngData(from: lineArt)
    }

    // MARK: Foreground-subject isolation (macOS 14+)

    static func isolateSubject(_ ci: CIImage) -> CIImage? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        guard (try? handler.perform([req])) != nil,
              let result = req.results?.first else { return nil }
        guard let masked = try? result.generateMaskedImage(
            ofInstances: result.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        ) else { return nil }
        return CIImage(cvPixelBuffer: masked)
    }

    // MARK: Document / rectangle detection

    static func detectDocument(in ci: CIImage) -> Quad? {
        let segReq = VNDetectDocumentSegmentationRequest()

        let rectReq = VNDetectRectanglesRequest()
        rectReq.minimumAspectRatio = 0.3
        rectReq.maximumAspectRatio = 1.6
        rectReq.minimumSize = 0.15
        rectReq.minimumConfidence = 0.5
        rectReq.maximumObservations = 1
        rectReq.quadratureTolerance = 45

        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        _ = try? handler.perform([segReq, rectReq])

        let obs: VNRectangleObservation? =
            segReq.results?.first ?? rectReq.results?.first
        guard let obs = obs else { return nil }

        let extent = ci.extent
        func pt(_ n: CGPoint) -> CGPoint {
            CGPoint(
                x: extent.origin.x + n.x * extent.width,
                y: extent.origin.y + n.y * extent.height
            )
        }
        return Quad(
            topLeft: pt(obs.topLeft),
            topRight: pt(obs.topRight),
            bottomLeft: pt(obs.bottomLeft),
            bottomRight: pt(obs.bottomRight)
        )
    }

    // MARK: Perspective correction

    static func perspectiveCorrect(_ ci: CIImage, quad: Quad) -> CIImage? {
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = ci
        f.topLeft = quad.topLeft
        f.topRight = quad.topRight
        f.bottomLeft = quad.bottomLeft
        f.bottomRight = quad.bottomRight
        return f.outputImage
    }

    // MARK: Line extraction via shading-corrected thresholding
    //
    // CILineOverlay is designed for turning photos into sketches; on an
    // already-line-drawn page it produces weird degenerate output (the edges
    // of each line are detected, which then all collapse to black). For
    // scanned line art the classical document-scanner trick works best:
    //
    //   1. Desaturate to grayscale.
    //   2. Estimate local illumination with a heavy Gaussian blur.
    //   3. `blurred - gray` is near-zero on the paper and positive where a
    //      line is darker than its surround → independent of exposure.
    //   4. Boost contrast so lines saturate.
    //   5. Alpha = luma, RGB = 0 → opaque black lines on transparent paper.
    static func lineOverlayPipeline(_ ci: CIImage) -> CIImage {
        let finite = ci.extent

        // 1. Desaturate + mild contrast + light sharpen so pencil edges pop
        //    a bit before we run the shading correction.
        let gray = ci
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 0.0,
                "inputBrightness": 0.0,
                "inputContrast": 1.15,
            ])
            .applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": 1.2,
                "inputIntensity": 0.5,
            ])

        // 2. Heavy Gaussian blur approximates each pixel's local paper tone.
        let blurRadius = min(finite.width, finite.height) * 0.035
        let blurred = gray
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                "inputRadius": blurRadius,
            ])
            .cropped(to: finite)

        // 3. blurred − gray is positive where the pixel is darker than the
        //    local average (i.e. a line stroke), near zero on plain paper.
        let sub = CIFilter.subtractBlendMode()
        sub.inputImage = blurred
        sub.backgroundImage = gray
        let hp = sub.outputImage ?? gray

        // 4. Single CIColorMatrix that does BOTH thresholding and the
        //    RGB→black / luma→alpha collapse in one shot:
        //
        //       alpha = gain * luma(hp) + bias
        //
        //    gain = 8, bias = -0.08 ⇒
        //       hp luma 0    (paper)  → alpha -0.08 → clamped 0  (transparent)
        //       hp luma 0.02 (noise)  → alpha 0.08  (barely visible)
        //       hp luma 0.05 (faint)  → alpha 0.32  (visible)
        //       hp luma 0.10 (medium) → alpha 0.72  (strong)
        //       hp luma 0.15+ (dark)  → alpha 1.12  → clamped 1  (fully opaque)
        //
        //    Much more sensitive than the old contrast-centered boost while
        //    still rejecting paper grain. Tune `gain` up for more ink, down
        //    for less noise.
        let gain: CGFloat = 8
        let bias: CGFloat = -0.08
        let lineArt = hp.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(
                x: gain * 0.299,
                y: gain * 0.587,
                z: gain * 0.114,
                w: 0
            ),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: bias),
        ])
        return lineArt.cropped(to: finite)
    }

    // MARK: Encoding

    static func pngData(from ci: CIImage) -> Data? {
        // PNG encoding requires a finite, non-empty extent. If a filter
        // upstream left us with infinite extent, log and bail so the caller
        // can retry instead of silently producing a nil PNG.
        guard !ci.extent.isInfinite, !ci.extent.isEmpty,
              ci.extent.width > 0, ci.extent.height > 0 else {
            NSLog("[LineExtractor] refusing to encode: bad extent \(ci.extent)")
            return nil
        }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let maxSide: CGFloat = 1400
        var image = ci
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxSide {
            let scale = maxSide / longest
            image = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let data = ctx.pngRepresentation(
            of: image,
            format: .RGBA8,
            colorSpace: space,
            options: [:]
        ) else {
            NSLog("[LineExtractor] pngRepresentation returned nil")
            return nil
        }
        return data
    }
}

struct Quad {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
}
