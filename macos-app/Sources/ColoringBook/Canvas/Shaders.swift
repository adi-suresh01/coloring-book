import Foundation

enum Shaders {
    /// Metal shader source, compiled at runtime via device.makeLibrary(source:).
    /// Embedded here so the executable Swift package doesn't need a metallib build step.
    static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    // ============================================================
    // Shared vertex output for a centered unit-quad fragment shader
    // ============================================================
    struct QuadV2F {
        float4 pos [[position]];
        float2 local;   // -1..1 in brush/cursor local space
    };

    // ============================================================
    // Brush stamping: draws one brush tip at a given canvas-pixel center.
    // Used in a render pass that writes into the offscreen canvas texture.
    // ============================================================
    struct BrushUniform {
        float2 center;      // canvas pixels
        float2 canvasSize;  // canvas texture dimensions
        float4 color;
        float  radius;      // canvas pixels
        float  opacity;
        float  seed;
        float  _pad;
    };

    vertex QuadV2F brush_vertex(
        uint vid [[vertex_id]],
        constant BrushUniform &u [[buffer(0)]]
    ) {
        float2 quad[6] = {
            float2(-1,-1), float2( 1,-1), float2(-1, 1),
            float2( 1,-1), float2( 1, 1), float2(-1, 1)
        };
        float2 local = quad[vid];
        float  expanded = u.radius * 1.3;
        float2 px = u.center + local * expanded;
        float2 ndc = (px / u.canvasSize) * 2.0 - 1.0;
        ndc.y = -ndc.y; // canvas y-down → NDC y-up
        QuadV2F o;
        o.pos = float4(ndc, 0, 1);
        o.local = local;
        return o;
    }

    // Hash helper (used by all textured brushes below).
    static inline float brushHash(float2 p, float seed) {
        float3 p3 = fract(float3(p.xyx) * 0.1031 + seed * 0.017);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    // ----- Sketchpen (felt-tip marker) ----------------------------------
    // Saturated, fairly opaque, soft but not fuzzy edge, faint alpha jitter
    // so large fills don't band.
    fragment float4 brush_sketchpen_fragment(
        QuadV2F in [[stage_in]],
        constant BrushUniform &u [[buffer(0)]]
    ) {
        float d = length(in.local);
        if (d > 1.0) discard_fragment();
        float a = smoothstep(1.0, 0.78, d) * 0.92;
        float n = brushHash(in.local * 8.0, u.seed);
        a *= (0.92 + 0.08 * n);
        return float4(u.color.rgb, a * u.opacity);
    }

    // ----- Color pencil --------------------------------------------------
    // Lower base opacity and a coarse, directional grain so paper texture
    // still shows through. Overlapping strokes build up depth.
    fragment float4 brush_pencil_fragment(
        QuadV2F in [[stage_in]],
        constant BrushUniform &u [[buffer(0)]]
    ) {
        float d = length(in.local);
        if (d > 1.0) discard_fragment();
        float body = smoothstep(1.0, 0.25, d);
        // Lean grain — streaks along one axis (pencil laydown direction).
        float grain = brushHash(float2(in.local.x * 30.0, in.local.y * 90.0), u.seed);
        // Pepper holes where the graphite missed paper bumps.
        float holes = brushHash(in.local * 18.0, u.seed + 4.7);
        float grainMask = mix(0.35, 1.0, grain);
        float holeMask = smoothstep(0.12, 0.35, holes);
        float a = body * grainMask * holeMask * 0.45;
        return float4(u.color.rgb, a * u.opacity);
    }

    // ----- Watercolor ----------------------------------------------------
    // Low alpha so layers pool; darker ring near the perimeter mimics the
    // wet-edge fringe where pigment accumulates as a puddle dries.
    fragment float4 brush_watercolor_fragment(
        QuadV2F in [[stage_in]],
        constant BrushUniform &u [[buffer(0)]]
    ) {
        float d = length(in.local);
        if (d > 1.0) discard_fragment();
        float body = smoothstep(1.0, 0.0, d) * 0.12;
        // Wet edge: narrow dark band near d ~ 0.85
        float wetEdge = smoothstep(0.72, 0.90, d) *
                        smoothstep(1.00, 0.90, d) * 0.35;
        // Gentle variance within the puddle so it doesn't look flat.
        float mottle = brushHash(in.local * 3.0, u.seed);
        float variance = mix(0.85, 1.0, mottle);
        float a = (body + wetEdge) * variance;
        return float4(u.color.rgb, a * u.opacity);
    }

    // ----- Crayon --------------------------------------------------------
    // Waxy, chunky — blocks of opacity separated by clean misses. Hard-ish
    // edge, uneven laydown.
    fragment float4 brush_crayon_fragment(
        QuadV2F in [[stage_in]],
        constant BrushUniform &u [[buffer(0)]]
    ) {
        float d = length(in.local);
        if (d > 1.0) discard_fragment();
        float body = smoothstep(1.0, 0.85, d) * 0.82;
        // Coarse, blocky grain
        float blockGrain = brushHash(floor(in.local * 14.0), u.seed);
        float grainMask = mix(0.45, 1.0, blockGrain);
        // Sparse misses where wax didn't contact the paper
        float miss = brushHash(floor(in.local * 6.0), u.seed + 11.3);
        float missMask = step(0.35, miss);
        float a = body * grainMask * missMask;
        return float4(u.color.rgb, a * u.opacity);
    }

    // ----- Pastel --------------------------------------------------------
    // Very soft, low-opacity, dusty. Fine grain, feathered edge.
    fragment float4 brush_pastel_fragment(
        QuadV2F in [[stage_in]],
        constant BrushUniform &u [[buffer(0)]]
    ) {
        float d = length(in.local);
        if (d > 1.0) discard_fragment();
        float body = smoothstep(1.0, 0.0, d) * 0.32;
        float dust = brushHash(in.local * 42.0, u.seed);
        float dustMask = mix(0.55, 1.0, dust);
        float a = body * dustMask;
        return float4(u.color.rgb, a * u.opacity);
    }

    // ============================================================
    // Full-screen composite: paper background + canvas texture.
    // ============================================================
    struct CompositeUniform {
        float2 size;   // view drawable size (pixels)
        float  time;
        float  zoom;   // local display zoom; 1 = fit canvas to view
        float2 pan;    // canvas-normalized offset; used when zoom>1 to pan
        float2 _pad;   // 16-byte alignment
    };

    struct FSV2F {
        float4 pos [[position]];
        float2 uv;
    };

    vertex FSV2F fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 quad[6] = {
            float2(-1,-1), float2( 1,-1), float2(-1, 1),
            float2( 1,-1), float2( 1, 1), float2(-1, 1)
        };
        float2 p = quad[vid];
        FSV2F o;
        o.pos = float4(p, 0, 1);
        // UV y-down (top-left origin) for canvas sampling
        o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
        return o;
    }

    // Value noise helpers
    static inline float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    static inline float valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float a = hash12(i);
        float b = hash12(i + float2(1, 0));
        float c = hash12(i + float2(0, 1));
        float d = hash12(i + float2(1, 1));
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    fragment float4 composite_fragment(
        FSV2F in [[stage_in]],
        constant CompositeUniform &u [[buffer(0)]],
        texture2d<float> canvas [[texture(0)]],
        texture2d<float> lineArt [[texture(1)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);

        // Map view-UV → canvas-UV through local zoom + pan. Pan shifts the
        // viewpoint around the canvas in normalized units; drag-direction ==
        // reveal-direction (dragging up-right shows the up-right area).
        float2 sampleUV = (in.uv - 0.5) / u.zoom + 0.5 + u.pan;

        // If the sample falls outside the canvas (zoomed in near an edge, or
        // zoomed out < 1), we render paper-only — no ink.
        bool outside = sampleUV.x < 0.0 || sampleUV.x > 1.0 ||
                       sampleUV.y < 0.0 || sampleUV.y > 1.0;
        float4 ink = outside ? float4(0) : canvas.sample(s, sampleUV);

        // Paper noise is driven off the *canvas*-space sample coord so paper
        // fibers have a fixed size on the page — they scale correctly with
        // zoom (magnified fibers when zoomed in) and don't stretch when the
        // window resizes.
        const float paperScale = 2200.0;
        float2 np = sampleUV * paperScale;

        // ---- Paper base: warm cream, slightly warmer than stock off-white --
        float3 paper = float3(0.980, 0.948, 0.886);

        // ---- Fiber texture: three octaves of value noise -------------------
        float fCoarse = valueNoise(np * 0.00016);
        float fMed    = valueNoise(np * 0.00050);
        float fFine   = valueNoise(np * 0.00160);
        float fiber = fCoarse * 0.50 + fMed * 0.30 + fFine * 0.20;
        paper *= (0.955 + 0.05 * (fiber - 0.5));

        // ---- Horizontally-anisotropic streaks ------------------------------
        float streaks = valueNoise(float2(np.x * 0.00030, np.y * 0.004));
        paper *= (0.985 + 0.018 * (streaks - 0.5));

        // ---- Broad tonal variance (paper is never uniform) -----------------
        float broad = valueNoise(sampleUV * 2.1);
        paper *= (0.972 + 0.04 * broad);

        // ---- Pulp specks: sparse tiny dark flecks --------------------------
        float speckField = valueNoise(np * 0.00045);
        float speckMask = smoothstep(0.86, 0.94, speckField);
        paper *= (1.0 - 0.10 * speckMask);

        // ---- Binding / gutter shadow on the left ---------------------------
        float binding = smoothstep(0.14, 0.00, sampleUV.x);
        paper *= (1.0 - 0.26 * binding);

        // ---- Warm top highlight (as if lit from above) ---------------------
        float topHighlight = smoothstep(0.55, 0.00, sampleUV.y) * 0.05;
        paper += topHighlight * float3(1.00, 0.95, 0.82);

        // ---- Page-corner curl shadows --------------------------------------
        float cornerX = min(sampleUV.x, 1.0 - sampleUV.x);
        float cornerY = min(sampleUV.y, 1.0 - sampleUV.y);
        float cornerD = cornerX * cornerY;
        float cornerShadow = smoothstep(0.035, 0.0, cornerD) * 0.08;
        paper *= (1.0 - cornerShadow);

        // ---- Gentle off-center radial falloff ------------------------------
        float2 centered = sampleUV - float2(0.52, 0.48);
        float vignette = 1.0 - dot(centered, centered) * 0.28;
        paper *= vignette;

        // Outside the canvas we still want the desk to read, not the paper.
        // Dim the paper drastically so the drop-shadow / desk take over.
        if (outside) { paper *= 0.0; return float4(paper, 0.0); }

        // Line art sits on top of everything (paper + ink), so coloring
        // "under the lines" still reads naturally. The line-art texture is
        // sampled with the same zoomed UV so it scales with the canvas.
        float4 lines = lineArt.sample(s, sampleUV);

        // ---- Composite: paper ← ink ← line art -----------------------------
        float3 outRGB = mix(paper, ink.rgb, ink.a);
        outRGB = mix(outRGB, lines.rgb, lines.a);
        return float4(outRGB, 1.0);
    }

    // ============================================================
    // Cursor overlay: ring (+ optional fill when drawing).
    // Drawn in view-drawable space on top of the composite.
    // ============================================================
    struct CursorUniform {
        float2 center;      // view pixels
        float2 viewSize;    // view drawable size
        float4 color;
        float  radius;      // view pixels
        float  ringWidth;
        float  filled;      // 0 = ring only, 1 = ring + inner fill
        float  _pad;
    };

    vertex QuadV2F cursor_vertex(
        uint vid [[vertex_id]],
        constant CursorUniform &u [[buffer(0)]]
    ) {
        float2 quad[6] = {
            float2(-1,-1), float2( 1,-1), float2(-1, 1),
            float2( 1,-1), float2( 1, 1), float2(-1, 1)
        };
        float2 local = quad[vid];
        float  expanded = u.radius + u.ringWidth + 2.0;
        float2 px = u.center + local * expanded;
        float2 ndc = (px / u.viewSize) * 2.0 - 1.0;
        ndc.y = -ndc.y;
        QuadV2F o;
        o.pos = float4(ndc, 0, 1);
        o.local = local * expanded; // in view pixels
        return o;
    }

    // Cursor with a contrasting white halo so it stays visible over any
    // ink color. Structure (outward from centre):
    //    |--- filled ink preview (when drawing) ---|
    //    |--- outer ring in ink color             ---|
    //    |--- white halo band around that          ---|
    fragment float4 cursor_fragment(
        QuadV2F in [[stage_in]],
        constant CursorUniform &u [[buffer(0)]]
    ) {
        float d = length(in.local);
        float r = u.radius;
        float halfW = u.ringWidth * 0.5;
        float haloW = 1.8;                       // thickness of the white band
        float distFromRing = fabs(d - r);

        // Coloured ring: within half of ringWidth of the ideal radius.
        float colored = 1.0 - smoothstep(halfW - 0.5, halfW + 0.5, distFromRing);

        // White halo: just outside the coloured ring.
        float haloReach = halfW + haloW;
        float haloBand = (1.0 - smoothstep(haloReach - 0.5, haloReach + 0.5, distFromRing))
                       * smoothstep(halfW - 0.5, halfW + 0.5, distFromRing);

        // Inner ink preview when actively drawing (filled blob inside ring).
        float inner = 0.0;
        if (u.filled > 0.5) {
            inner = smoothstep(r - halfW, r - halfW - 2.0, d) * 0.40;
        }

        // Pick the frontmost non-zero band: inner ink over colored ring over halo.
        float3 rgb;
        float a;
        if (inner > 0.01 && d < r - halfW) {
            rgb = u.color.rgb;
            a = inner;
        } else if (colored >= haloBand * 0.5) {
            rgb = u.color.rgb;
            a = colored;
        } else {
            rgb = float3(1.0, 1.0, 1.0);
            a = haloBand * 0.85;
        }

        if (a < 0.01) discard_fragment();
        return float4(rgb, a);
    }
    """
}
