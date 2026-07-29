import Foundation

/// One visual.
///
/// A scene owns its shader and its own ballistics, and fills a single data
/// buffer the fragment shader reads. Keeping the contract this narrow means
/// adding a visual touches exactly one new file, as on Android.
protocol VeloScene: AnyObject {
    /// Shown in the controls and used for the window subtitle.
    var name: String { get }
    /// Metal Shading Language source. Must define `veloVertex` and `veloFragment`.
    var shaderSource: String { get }
    /// Advance any smoothing or ballistics this scene keeps.
    func update(audio: AudioEngine, dt: Float)
    /// Write this frame's values into the shared scene buffer (buffer index 1).
    func writeData(into pointer: UnsafeMutableRawPointer)
}

extension VeloScene {
    /// Every scene shares one vertex stage: a fullscreen triangle generated from
    /// `vertex_id` alone. No vertex buffer, and no seam down the diagonal that a
    /// two-triangle quad would have.
    static var fullscreenVertexShader: String {
        """
        struct VSOut { float4 position [[position]]; };

        vertex VSOut veloVertex(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            VSOut out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            return out;
        }
        """
    }

    /// Shared preamble: uniforms, and the flip that puts the origin bottom-left.
    /// Metal's framebuffer origin is top-left, which would stand every
    /// instrument on its head.
    static var shaderPreamble: String {
        """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 resolution;
            float  time;
            float  dim;
        };
        """
    }
}
