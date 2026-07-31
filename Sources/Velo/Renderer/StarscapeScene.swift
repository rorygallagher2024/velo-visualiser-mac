import Foundation

/// "Starscape" — ported from Android.
///
/// A hyperspace star field flying toward the viewer. Stars loop through depth
/// and rush outward from the vanishing point as they arrive, smearing into
/// radial streaks at speed. Bass accelerates the warp and swells the stars,
/// highs drive a per-star twinkle, and each beat bursts a third of the field
/// into a fresh colour.
///
/// Drawn as point sprites, the way the Android original draws it. The first
/// attempt here searched a per-pixel hash grid for stars instead, which is the
/// wrong tool twice over: a star is a sub-pixel object, so point-sampling one
/// at pixel centres snapped it into hard blocks rather than fading, and
/// thirty-two grid layers were walked per pixel to find a few hundred stars —
/// 5 ms at two megapixels, four times that on a real fullscreen canvas. A
/// sprite is O(stars) rather than O(pixels x layers), and it is analytically
/// smooth at any resolution.
///
/// There is still no vertex buffer. Each star's direction and depth seed come
/// from hashing its own `vertex_id`, which is the same fixed random set the
/// Android VBO holds, generated where it is read instead of uploaded.
final class StarscapeScene: VeloScene {

    let name = "Starscape"

    /// More than Android's 1800: a Mac canvas is several times the area of a
    /// phone's and the field reads as sparse at the same count.
    private static let starCount = 3000

    let draw = SceneDraw.points(StarscapeScene.starCount)

    private var energy = BandEnergy()
    private var travel: Float = 0
    private var warpRate: Float = 0
    private var flash: Float = 0
    private var flashHue: Float = 0
    private var lastBeatCount = 0

    private let baseSpeed: Float = 0.06     // depth units per second
    private let bassBoost: Float = 0.28     // extra speed at full bass
    private let flashFall: Float = 3.0      // beat-flash fade, ~0.33 s

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)

        // Kept as a rate as well as an accumulation: the shader needs the
        // current speed to work out how far each star moved, and so how long
        // its streak should be.
        warpRate = baseSpeed + energy.low * bassBoost
        // Wrapped, not left to grow. Depth is read through fract() anyway, and
        // an ever-climbing float loses the precision the wrap depends on.
        travel = (travel + warpRate * dt).truncatingRemainder(dividingBy: 1)

        let bus = BeatBus.current
        if BeatBus.showBeatsOnVisuals, bus.beatCount != lastBeatCount {
            lastBeatCount = bus.beatCount
            flash = 1
            flashHue = (flashHue + 0.37).truncatingRemainder(dividingBy: 1)
        } else {
            lastBeatCount = bus.beatCount
            flash = max(flash - dt * flashFall, 0)
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 6)
        p[0] = travel
        p[1] = energy.low
        p[2] = energy.high
        p[3] = flash
        p[4] = flashHue
        p[5] = warpRate
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct StarData {
            float travel;
            float bass;
            float high;
            float flash;
            float flashHue;
            float warp;      // depth units per second, for the streak length
        };

        constant float FLASH_FRAC     = 0.35;   // share of stars that burst
        constant float STREAK_SECONDS = 0.05;   // shutter time for the smear
        constant float MAX_SPRITE_PX  = 192.0;  // bound on a near star's fill

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float3 tint;
            float  bright;
            float  seed;
            float  sel;
            float2 dir;      // streak axis, in sprite space
            float  stretch;  // sprite length over sprite width
        };

        // One float in, three out. Enough decorrelation to place a star, pick
        // its depth and vary its colour from nothing but its index.
        static inline float3 hash31(float p) {
            float3 p3 = fract(float3(p) * float3(0.1031, 0.1030, 0.0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.xxy + p3.yzz) * p3.zyx);
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        // Radial expansion. Stars crowd the vanishing point while far away and
        // accelerate off the edge as they arrive; the 0.98 is how hard that
        // acceleration bites.
        static inline float spreadAt(float z) {
            return z / (1.0 - z * 0.98);
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant StarData &s [[buffer(1)]])
        {
            float3 h = hash31(float(vid) + 1.0);

            // xy is the star's fixed direction from the centre, z its depth
            // seed — the same three floats per star the Android VBO carries.
            float2 dirSeed = h.xy * 2.0 - 1.0;

            // A star sitting exactly on the vanishing point never moves and
            // never streaks, so push the innermost ones out to a floor.
            float r0 = max(length(dirSeed), 1e-5);
            dirSeed *= max(r0, 0.05) / r0;

            float z = fract(h.z + s.travel);          // 0 far .. 1 near

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 halfRes = u.resolution * 0.5;

            float2 clipNow = dirSeed * spreadAt(z);
            clipNow.x /= aspect;

            // Where it was a moment ago, which is the streak. STREAK_SECONDS
            // is a shutter time rather than the frame time: measuring it in
            // frames would lengthen every streak whenever the rate dropped.
            float zPrev = max(z - s.warp * STREAK_SECONDS, 0.0);
            float2 clipPrev = dirSeed * spreadAt(zPrev);
            clipPrev.x /= aspect;

            // Clip space spans -1..1 across the whole canvas, so half the
            // resolution converts a clip delta into pixels.
            float2 deltaPx = (clipNow - clipPrev) * halfRes;
            float trailPx = length(deltaPx);
            float2 dir = trailPx > 1e-4 ? deltaPx / trailPx : float2(1.0, 0.0);

            // A second, independent draw for the star's own character.
            float3 g = hash31(float(vid) * 1.618 + 91.7);
            float sel = g.x;
            float seed = g.y;
            float flashStar = step(sel, FLASH_FRAC);

            // Sizes are pixels at a 1080-tall reference, scaled with the canvas
            // so a star stays the same apparent size on a 4K display instead of
            // shrinking to a speck.
            float dpi = max(u.resolution.y / 1080.0, 1.0);
            float corePx = mix(1.5, 5.0, z) * dpi * (1.0 + s.bass * 1.6);
            corePx *= 1.0 + s.flash * flashStar * 1.6;
            // Never below a pixel and a half. A sprite smaller than a pixel is
            // exactly the aliasing this visual used to have: it flickers as it
            // crosses pixel centres instead of fading. Depth is carried by
            // brightness instead, which has no such floor.
            corePx = max(corePx, 1.5);

            float lenPx = min(corePx + trailPx, MAX_SPRITE_PX);

            VSOut out;
            out.position = float4(clipNow, 0.0, 1.0);
            out.size = lenPx;
            out.stretch = lenPx / corePx;

            // point_coord runs y-down from the sprite's top-left while clip
            // space runs y-up, so the streak axis has to be mirrored or half
            // the field smears the wrong way.
            out.dir = float2(dir.x, -dir.y);

            // Fade in at the horizon and out at the edge, so the depth
            // wrap-around is invisible.
            float fade = smoothstep(0.0, 0.05, z) * (1.0 - smoothstep(0.92, 1.0, z));
            float bright = z * z * fade;
            // Spread the same light along a longer streak rather than letting
            // fast stars turn into solid bars.
            out.bright = bright / pow(out.stretch, 0.35);

            out.tint = mix(float3(0.6, 0.75, 1.0), float3(1.0, 0.95, 0.85), seed);
            out.seed = seed;
            out.sel = sel;
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant StarData &s [[buffer(1)]])
        {
            // Sprite-local, -1..1 across the square.
            float2 c = pc * 2.0 - 1.0;

            // Into the streak's own frame: x along the direction of travel, y
            // across it. The sprite is square; the star is not, so the across
            // axis is scaled up until the unit circle becomes the right ellipse.
            float2 t = float2(dot(c, in.dir), dot(c, float2(-in.dir.y, in.dir.x)));
            t.y *= in.stretch;

            float d = dot(t, t);
            if (d > 1.0) { discard_fragment(); }

            float glow = exp(-d * 3.0);

            float twinkle = 0.7 + 0.3 * sin(u.time * 6.0 + in.seed * 100.0);
            twinkle = mix(1.0, twinkle, s.high);     // highs drive the twinkle

            float3 col = in.tint * in.bright * glow * twinkle;
            col *= 1.0 + s.bass * 2.0;               // HDR on the beat

            // Beat flash: a third of the stars burst bright in a per-beat hue.
            float flashStar = step(in.sel, FLASH_FRAC);
            float3 flashCol = palette(s.flashHue + in.sel);
            col += flashStar * s.flash * flashCol * glow * (0.6 + in.bright * 3.0);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
