import Foundation
import Metal

/// "Abstract Waveform"
///
/// A real, 9-second rolling waveform history (like a DAW), but rendered
/// as crisp, transparent, anti-aliased outlines rather than solid blobs.
/// It uses the actual raw PCM audio split via Linkwitz-Riley crossovers.
final class AbstractWaveformScene: VeloScene {

    let name = "Abstract Waveform"

    private let history = WaveHistory()

    var historyBuffer: MTLBuffer? { history.gpuBuffer }

    func prepare(device: MTLDevice) { history.prepare(device: device) }

    func update(audio: AudioEngine, dt: Float) { history.consume(audio: audio) }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var head = history.headFraction
        pointer.copyMemory(from: &head, byteCount: MemoryLayout<Float>.stride)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Roll { float head; };

        \(Self.fullscreenVertexShader)

        constant int   SLICES  = \(WaveHistory.slices);
        constant int   FIELDS  = \(WaveHistory.fields);
        constant float VISIBLE = \(WaveHistory.visible).0;

        static inline int wrapSlice(int si) {
            int tx = si % SLICES;
            return tx < 0 ? tx + SLICES : tx;
        }

        // The envelopes as continuous piecewise-linear functions of slice
        // position, interpolated between adjacent committed columns.
        static inline void envAt(device const float *h, float s,
                                 thread float3 &bands) {
            float fl = floor(s);
            float f = s - fl;
            int a = wrapSlice(int(fl)) * FIELDS;
            int b = wrapSlice(int(fl) + 1) * FIELDS;
            bands = mix(float3(h[a], h[a + 1], h[a + 2]),
                        float3(h[b], h[b + 1], h[b + 2]), f);
        }

        // Draw a mirrored, transparent outline of a waveform envelope
        static inline float renderWaveformOutline(float fragY, float yCenter, float amplitude, float ext) {
            // Calculate absolute distance from center (for mirroring)
            float distFromCenter = abs(fragY - yCenter);
            
            // The actual edge of the envelope at this pixel X
            float targetExt = ext * amplitude;
            
            // Distance to the outline
            float outlineDist = abs(distFromCenter - targetExt);
            
            // Crisp, anti-aliased line
            float line = smoothstep(1.5, 0.0, outlineDist);
            
            // Erase the line entirely when it sits perfectly flat at the zero-axis,
            // so we only see the "active" bubbles of the waveform.
            float axisMask = smoothstep(0.5, 2.0, targetExt);
            
            return line * axisMask;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Roll &r [[buffer(1)]],
                                     device const float *h [[buffer(2)]])
        {
            // Standard coordinate system
            float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
            float x01 = frag.x / u.resolution.x;              // 0 left, 1 right
            float slice = r.head - 1.0 - (1.0 - x01) * VISIBLE;
            float spp = max(VISIBLE / u.resolution.x, 1.0);   // slices per pixel

            // Exact rasterisation of the envelope over this pixel's span.
            float sL = slice - 0.5 * spp;
            float sR = min(slice + 0.5 * spp, r.head - 1.0);   // never past the pen
            
            float3 bandL; envAt(h, sL, bandL);
            float3 bandR; envAt(h, sR, bandR);
            float3 bandExt = max(bandL, bandR);

            int iA = int(ceil(sL));
            for (int k = 0; k < 8; k++) {
                int si = iA + k;
                if (float(si) > sR) { break; }
                int t = wrapSlice(si) * FIELDS;
                bandExt = max(bandExt, float3(h[t], h[t + 1], h[t + 2]));
            }

            float3 finalColor = float3(0.0);
            
            float masterAmplitude = u.resolution.y * 0.15; // Max height of each waveform
            
            // 1. Treble Waveform (Top)
            float hiY = u.resolution.y * 0.8;
            float hiIntensity = renderWaveformOutline(frag.y, hiY, masterAmplitude, bandExt.z);
            finalColor += float3(0.2, 0.5, 1.0) * hiIntensity;

            // 2. Mid Waveform (Center)
            float midY = u.resolution.y * 0.5;
            float midIntensity = renderWaveformOutline(frag.y, midY, masterAmplitude, bandExt.y);
            finalColor += float3(0.1, 1.0, 0.5) * midIntensity;

            // 3. Bass Waveform (Bottom)
            float bassY = u.resolution.y * 0.2;
            float bassIntensity = renderWaveformOutline(frag.y, bassY, masterAmplitude, bandExt.x);
            finalColor += float3(1.0, 0.1, 0.2) * bassIntensity;
            
            // The live edge (newest audio on the right) is drawn brightest,
            // and it slightly cools/dims as it scrolls left into history.
            float age = max(r.head - 1.0 - slice, 0.0);
            float fade = exp(-age / (VISIBLE * 0.5)); // smooth exponential decay over time
            finalColor *= (0.5 + 0.5 * fade);
            
            return float4(finalColor * u.dim, 1.0);
        }
        """
    }
}
