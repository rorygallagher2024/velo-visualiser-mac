import Foundation
import Metal

/// "Cyber Horizon" — Minimalist Perspective Vector Grid for DJ Overlays.
///
/// Anchors the bottom third of the video feed (under the DJ mixer/decks) with
/// an ultra-clean, razor-sharp vector grid receding into the horizon. The upper
/// 60% of the screen is completely clear for camera footage.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Propagates topographic elevation waves backwards into depth.
/// - Midrange: Fires luminous vector packets along grid lines.
/// - Treble / Hi-hats: Triggers horizon line pulses and vertical laser nodes.
/// - Silence / Breakdowns: Dims to black via BandGate.
final class CyberHorizonScene: VeloScene {

    let name = "Cyber Horizon"

    private var gate = BandGate()

    private var gridScroll: Float = 0
    private var pulsePhase: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let midBass = gate.level[1]
        let mids = gate.level[2]

        // Grid flows toward the camera smoothly
        gridScroll += dt * (0.40 + lowBass * 0.90 + midBass * 0.50)
        pulsePhase += dt * (1.50 + mids * 3.00)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 7)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = gridScroll
        p[6] = pulsePhase
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct HorizonData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float gridScroll;
            float pulsePhase;
        };

        \(Self.fullscreenVertexShader)

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant HorizonData &s [[buffer(1)]])
        {
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Horizon position sits below the center (framing under the decks)
            float horizonY = -0.05;
            if (p.y > horizonY + 0.08) {
                return float4(0.0);
            }

            // Perspective floor ray projection
            float dy = horizonY - p.y;
            float floorDist = 0.55 / max(dy, 0.001);
            float floorX = p.x * floorDist;
            float floorZ = floorDist + s.gridScroll;

            // Audio-driven elevation wave ripple on the floor
            float wave = sin(floorZ * 1.5 - s.gridScroll * 3.0) * s.lowBass * 0.35;
            float floorZ_distorted = floorZ + wave;

            // Grid coordinates
            float gridX = abs(fract(floorX * 1.2) - 0.5);
            float gridZ = abs(fract(floorZ_distorted * 0.8) - 0.5);

            // Anti-aliased line rendering
            float dGridX = gridX * dy * 12.0;
            float dGridZ = gridZ * dy * 12.0;

            float lineX = exp(-dGridX * dGridX * 2200.0);
            float lineZ = exp(-dGridZ * dGridZ * 2200.0);
            float grid = max(lineX, lineZ);

            // Depth fog fade toward the horizon
            float fog = smoothstep(0.0, 0.08, dy) * exp(-dy * 1.8);

            // Luminous data pulses moving along grid lanes
            float pulse = sin(floorZ * 2.0 - s.pulsePhase * 3.0);
            float pulseGlow = max(pulse, 0.0) * lineZ * (0.8 + s.mids * 2.0);

            // Horizon laser line
            float horizonLaser = exp(-pow(abs(p.y - horizonY), 2.0) * 1400.0) * (0.6 + s.treble * 1.8);

            // Palette: Cyber Neon Cyan / Magenta Horizon
            float3 gridCyan    = float3(0.20, 0.85, 1.00);
            float3 laserPink   = float3(1.00, 0.25, 0.65);
            float3 horizonBlue = float3(0.40, 0.60, 1.00);

            float3 col = float3(0.0);
            col += gridCyan * grid * fog * (0.6 + s.midBass * 0.8);
            col += laserPink * pulseGlow * fog;
            col += horizonBlue * horizonLaser * exp(-abs(p.x) * 1.2);

            // Top fade mask
            col *= smoothstep(horizonY + 0.08, horizonY - 0.02, p.y);
            col *= s.presence * (0.85 + s.lowBass * 0.5) * u.dim;

            float3 finalColor = themeGrade(col, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
