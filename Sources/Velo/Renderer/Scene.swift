import Foundation
import Metal

/// What a scene draws, and how its fragments combine.
///
/// Almost every visual is one fullscreen triangle with the fragment shader
/// doing all the work, which is the default. Particle fields are the exception,
/// and the reason this exists: a star field is thousands of discrete objects
/// each smaller than a pixel, and hunting for them with a per-pixel hash grid
/// is wrong twice over. It aliases — a sub-pixel point sampled at pixel centres
/// snaps into hard blocks rather than fading — and it pays for every empty cell
/// it walks. Drawn as point sprites the same field costs O(stars) instead of
/// O(pixels x layers), and each sprite is an analytic shape that stays smooth
/// at any canvas size.
struct SceneDraw {
    var primitive: MTLPrimitiveType = .triangle
    var vertexCount: Int = 3
    /// Additive blending, so overlapping glows accumulate instead of the last
    /// one drawn winning. Depth in a particle field reads from that stacking.
    var additive: Bool = false

    static let fullscreenTriangle = SceneDraw()

    /// `count` point sprites, additively blended. The vertex shader derives
    /// each particle from its own `vertex_id`, so there is still no vertex
    /// buffer and nothing to upload per frame.
    static func points(_ count: Int) -> SceneDraw {
        SceneDraw(primitive: .point, vertexCount: count, additive: true)
    }
}

/// One visual.
///
/// A scene owns its shader and its own ballistics, and fills a single data
/// buffer the fragment shader reads. Keeping the contract this narrow means
/// adding a visual touches exactly one new file, as on Android.
protocol VeloScene: AnyObject {
    /// What to draw. Defaults to the fullscreen triangle every shader scene uses.
    var draw: SceneDraw { get }
    /// Shown in the controls and used for the window subtitle.
    var name: String { get }
    /// Metal Shading Language source. Must define `veloVertex` and `veloFragment`.
    var shaderSource: String { get }
    /// Advance any smoothing or ballistics this scene keeps.
    func update(audio: AudioEngine, dt: Float)
    /// Write this frame's values into the shared scene buffer (buffer index 1).
    func writeData(into pointer: UnsafeMutableRawPointer)
    /// Build any GPU resources of this scene's own. Called once, at startup.
    func prepare(device: MTLDevice)
    /// A persistent buffer this scene owns and writes into directly, bound at
    /// buffer index 2.
    ///
    /// For history too large to hand over every frame. Shared storage, so the
    /// scene writes straight into the memory the GPU reads and there is no
    /// upload at all. This exists instead of a texture because `replace(region:)`
    /// on a texture the GPU may be reading serialises the queue: measured at
    /// 0.8 fps with the GPU sitting at 2.1 ms.
    var historyBuffer: MTLBuffer? { get }
}

extension VeloScene {
    func prepare(device: MTLDevice) {}
    var historyBuffer: MTLBuffer? { nil }
    var draw: SceneDraw { .fullscreenTriangle }

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
