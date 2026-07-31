import Foundation

/// "Crystal Swarm" — ported from Android.
///
/// A dense 3D particle cloud arranged as a lattice that breathes and rotates.
/// Bass drives waves through the grid; mids and highs push dots outward from
/// the centre; the beat envelope blooms every point into a bright flash. A
/// slowly orbiting camera with perspective projection gives it depth. The
/// colour palette shifts spatially across the grid and temporally with beats,
/// so the swarm never looks monochrome.
///
/// Android uses a 32x32x32 = 32,768 particle VBO. Here each particle's grid
/// position is recovered from its `vertex_id` with simple integer division,
/// keeping the same lattice layout with no buffer to allocate or upload.
final class CrystalSwarmScene: VeloScene {

    let name = "Crystal Swarm"

    private static let gridSize = 32
    private static let count = gridSize * gridSize * gridSize

    let draw = SceneDraw.points(CrystalSwarmScene.count)

    private var energy = BandEnergy()
    private var smoothedBass: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedHigh: Float = 0
    private var currentMorph: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        let bass = max(energy.low - 0.15, 0) * 1.15
        let mid  = max(energy.mid - 0.15, 0) * 1.15
        let high = max(energy.high - 0.15, 0) * 1.15

        smoothedBass += (bass - smoothedBass) * 0.15
        smoothedMid  += (mid  - smoothedMid)  * 0.15
        smoothedHigh += (high - smoothedHigh) * 0.15

        let target = min(smoothedBass * 2.0, 1.0)
        currentMorph += (target - currentMorph) * 0.08
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 5)
        p[0] = smoothedBass
        p[1] = smoothedMid
        p[2] = smoothedHigh
        p[3] = energy.envelope
        p[4] = currentMorph
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct SwarmData {
            float bass;
            float mid;
            float high;
            float env;
            float morph;
        };

        constant int GRID = \(Self.gridSize);

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float3 gridPos;
            float  energy;
            float  beat;
            float  depth;
        };

        static inline float hash11(float p) {
            p = fract(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return fract(p);
        }

        static inline float3 palette(float t) {
            float3 a = float3(0.5);
            float3 b = float3(0.5);
            float3 c = float3(1.0);
            float3 d = float3(0.0, 0.33, 0.67);
            return a + b * cos(6.28318 * (c * t + d));
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant SwarmData &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float dpi = max(u.resolution.y / 1080.0, 1.0);

            int ix = int(vid) % GRID;
            int iy = (int(vid) / GRID) % GRID;
            int iz = int(vid) / (GRID * GRID);

            float step = 2.0 / float(GRID - 1);
            float3 gridPos = float3(
                -1.0 + float(ix) * step,
                -1.0 + float(iy) * step,
                -1.0 + float(iz) * step
            );
            float seed = hash11(float(vid) * 0.0131 + 7.0);
            float jitter = 0.01;
            gridPos += (float3(hash11(float(vid) * 0.0307),
                               hash11(float(vid) * 0.0511),
                               hash11(float(vid) * 0.0713)) * 2.0 - 1.0) * jitter;

            float3 pos = gridPos * 2.0;

            float wave1 = sin(pos.x * 1.5 + u.time * 0.3) * cos(pos.z * 1.5 - u.time * 0.2);
            float wave2 = sin(pos.y * 2.0 - u.time * 0.4);
            float3 waveOff = float3(wave2, wave1, wave1 * wave2) * 0.3 * (1.0 + s.bass * 3.0);
            pos += waveOff;

            float dist = length(pos) + 0.01;
            pos += (pos / dist) * (s.mid + s.high) * 0.2 * seed;

            float phase = (u.time * 0.1);
            float angleY = u.time * 0.05 + phase * 6.28318;
            float angleX = sin(u.time * 0.03) * 0.2 + 0.4;

            float cY = cos(angleY), sY = sin(angleY);
            float xRot = pos.x * cY - pos.z * sY;
            float zRot1 = pos.x * sY + pos.z * cY;
            pos.x = xRot;
            pos.z = zRot1;

            float cX = cos(angleX), sX = sin(angleX);
            float yRot = pos.y * cX - pos.z * sX;
            float zRot = pos.y * sX + pos.z * cX;
            pos.y = yRot;
            pos.z = zRot;

            float camZ = 5.0 - s.bass * 0.5;
            float zDepth = camZ + pos.z;
            float proj = 1.0 / max(zDepth, 0.1);

            float2 ndc = float2(pos.x * proj, pos.y * proj) * 2.5;
            ndc.x /= aspect;

            float baseSize = mix(1.0, 2.5, seed);
            float sz = baseSize * dpi * proj;
            sz *= 1.0 + s.env * 3.0 + s.high * 2.0;

            VSOut out;
            out.position = float4(ndc, 0.0, 1.0);
            out.size = max(sz, 1.0);
            out.gridPos = gridPos;
            out.energy = s.bass * 0.4 + s.mid * 0.3 + s.high * 0.3;
            out.beat = s.env;
            out.depth = proj;
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d = dot(c, c);
            if (d > 1.0) { discard_fragment(); }

            float core = exp(-d * 3.5);
            float phase = (u.time * 0.1);
            float spatialHue = (in.gridPos.x * 0.3 + in.gridPos.y * 0.4 + in.gridPos.z * 0.3)
                             + phase + in.beat * 0.5;
            float3 col = palette(spatialHue);

            float brightness = 1.0 + in.energy * 2.5 + in.beat * 3.0;
            col *= brightness;
            col *= core;
            // Depth fades far particles but only gently — the perspective
            // projection already shrinks them, so dimming on top makes the
            // back of the cloud vanish entirely.
            col *= 0.4 + in.depth * 1.5;

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
