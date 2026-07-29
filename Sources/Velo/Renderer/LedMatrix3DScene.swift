import Foundation

/// "3D LED" — ported from Android.
///
/// The Pocket LED panel as an actual object: a raymarched grid of rounded LED
/// lenses protruding through a matte chassis, lit and specular, with an
/// isometric camera drifting slowly around it. Lit cells run a deep orange to
/// cyan gradient across the board and emit past 1.0 so they bloom; peaks are
/// stark white.
///
/// The chassis is what sells it. Without a slab behind them the lenses read as
/// cubes floating in a void rather than as a built device, so the SDF is the
/// minimum of the LED grid and a rounded box sized with a bezel margin.
///
/// The camera basis is right-handed on purpose: `cross(up, forward)` rather
/// than `cross(forward, up)`. With the camera on the negative Z side the other
/// order mirrors the board, putting bass on the right.
final class LedMatrix3DScene: VeloScene {

    static let cols = 24
    static let rows = 14

    let name = "3D LED"

    private var columns = ColumnBallistics(count: LedMatrix3DScene.cols)

    init() {
        columns.instantAttack = true      // an LED has no mass to accelerate
        columns.releaseRate = 7           // about a 0.14 s fall
        columns.peakHoldSec = 0.7
        columns.peakGravity = 1.1
    }

    func update(audio: AudioEngine, dt: Float) {
        columns.update(targets: ColumnBallistics.fold(audio.currentBins(), into: Self.cols), dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) { columns.write(into: pointer) }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Panel { float level[\(Self.cols)]; float peak[\(Self.cols)]; };

        \(Self.fullscreenVertexShader)

        constant float COLS = float(\(Self.cols));
        constant float ROWS = float(\(Self.rows));

        static inline float sdRoundBox(float3 p, float3 b, float r) {
            float3 q = abs(p) - b;
            return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
        }

        static inline float2 cubeID(float3 p) {
            return float2(clamp(floor(p.x + 0.5), 0.0, COLS - 1.0),
                          clamp(floor(p.y + 0.5), 0.0, ROWS - 1.0));
        }

        // The device body: a rounded slab just behind the LEDs, sized with a
        // bezel margin so the grid reads as a built object rather than as cubes
        // floating in a void. The lenses protrude through its face.
        static inline float sdChassis(float3 p) {
            float3 c = float3((COLS - 1.0) * 0.5, (ROWS - 1.0) * 0.5, 1.05);
            return sdRoundBox(p - c, float3(COLS * 0.5 + 0.9, ROWS * 0.5 + 0.9, 0.35), 0.30);
        }

        static inline float mapScene(float3 p) {
            float3 q = p;
            q.xy -= cubeID(p);
            return min(sdRoundBox(q, float3(0.35), 0.08), sdChassis(p));
        }

        static inline float3 calcNormal(float3 p) {
            float2 e = float2(1.0, -1.0) * 0.5773 * 0.005;
            return normalize(e.xyy * mapScene(p + e.xyy) + e.yyx * mapScene(p + e.yyx) +
                             e.yxy * mapScene(p + e.yxy) + e.xxx * mapScene(p + e.xxx));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Panel &s [[buffer(1)]])
        {
            float2 fc = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = (fc - 0.5 * u.resolution) / min(u.resolution.x, u.resolution.y);
            uv *= 1.25;                       // sit the board comfortably in frame

            float3 centre = float3((COLS - 1.0) * 0.5, (ROWS - 1.0) * 0.5, 0.0);

            // Isometric camera, drifting slowly around the board.
            float3 ro = centre + float3(18.0 * sin(u.time * 0.15),
                                        12.0 + 4.0 * cos(u.time * 0.2),
                                        -26.0);
            float3 ww = normalize(centre - ro);
            // Right-handed: cross(up, forward). The other order mirrors the
            // board and puts bass on the right.
            float3 uu = normalize(cross(float3(0.0, 1.0, 0.0), ww));
            float3 vv = normalize(cross(ww, uu));
            float3 rd = normalize(uv.x * uu + uv.y * vv + 1.6 * ww);

            // Dither the start so the steps do not band.
            float t = fract(sin(dot(fc, float2(12.9898, 78.233))) * 43758.5453) * 0.1;
            float3 p = ro;
            for (int i = 0; i < 60; i++) {
                p = ro + rd * t;
                float d = mapScene(p);
                if (d < 0.005 || t > 100.0) break;
                t += d;
            }

            float3 col = float3(0.0);        // deep void background

            if (t < 100.0) {
                float2 id = cubeID(p);
                float3 n = calcNormal(p);
                float3 qh = p; qh.xy -= id;
                bool onChassis = sdChassis(p) < sdRoundBox(qh, float3(0.35), 0.08);

                int idx = clamp(int(id.x), 0, \(Self.cols) - 1);
                float mag = s.level[idx];
                float peak = s.peak[idx];

                bool isLit = id.y < mag * ROWS;
                bool isPeak = abs(id.y - floor(peak * ROWS - 0.001)) < 0.1 && peak > 0.02;

                float3 matColor = float3(0.045);   // unlit dark lens, visible hardware
                float emission = 0.0;

                if (onChassis) {
                    matColor = float3(0.05);       // matte housing
                } else if (isPeak) {
                    matColor = float3(1.0, 0.95, 0.9);
                    emission = 2.0;
                } else if (isLit) {
                    matColor = mix(float3(1.0, 0.35, 0.05), float3(0.0, 0.85, 1.0), id.x / COLS);
                    emission = 0.8 + (id.y / ROWS) * 0.7;   // blooms harder up the bar
                }

                float3 l = normalize(float3(0.5, 1.0, -0.8));
                float diff = max(dot(n, l), 0.0);
                // Sharp highlight for the glass lens feel, dialled back on the
                // matte housing so it does not glare.
                float3 h = normalize(l - rd);
                float spec = pow(max(dot(n, h), 0.0), 64.0) * (onChassis ? 0.25 : 1.0);

                col = matColor * (diff + 0.15) + spec * 0.6;
                col += matColor * emission;
                // Fresnel edge glow, standing in for thick-glass internal reflection.
                col += pow(1.0 - max(dot(n, -rd), 0.0), 4.0) * matColor * 0.5;
            }

            return float4(col * u.dim, 1.0);
        }
        """
    }
}
