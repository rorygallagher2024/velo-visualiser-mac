import Foundation
@preconcurrency import Metal
import QuartzCore
import simd

/// Per-frame values handed to the shader. Must match `Uniforms` in the MSL
/// source exactly.
struct Uniforms {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var dim: Float = 1
    var hueShift: Float = 0
    var saturation: Float = 1
    var tintR: Float = 1
    var tintG: Float = 1
    var tintB: Float = 1
    var mixAlpha: Float = 1
}

/// The Metal 4 renderer.
///
/// Metal 4 (macOS 26) makes explicit what Metal 3 inferred: command buffers are
/// recorded into an `MTL4CommandAllocator` the app resets itself, pipelines come
/// from an `MTL4Compiler`, bindings live in an `MTL4ArgumentTable`, and drawable
/// ordering is stated with `waitForDrawable` / `signalDrawable`. The cost is more
/// setup; the benefit is that nothing about frame pacing is hidden in the driver.
///
/// Frame pacing is the part worth reading carefully. There are two independent
/// resources that can stall a frame — a free drawable, and a free slot of
/// per-frame buffers — and they MUST be the same count, acquired in the right
/// order. Getting either wrong shows up as a framerate that is fine in a window
/// and collapses in fullscreen, because the symptom scales with GPU frame time.
final class Renderer: @unchecked Sendable {

    /// Two, matching `CAMetalLayer.maximumDrawableCount`. Any mismatch means
    /// one of the two throttles is dead weight and the other blocks early.
    ///
    /// Three, not two.
    ///
    /// Two was chosen for latency, on the reasoning that a third drawable only
    /// absorbs GPU overruns and this GPU never overruns. That was measured in a
    /// WINDOW, where it is true. In a fullscreen Space the display holds a
    /// drawable for longer, and two is not enough to keep the pipeline fed:
    ///
    ///     2 drawables, fullscreen:  40.0 fps, waitDrawable 24.9 ms
    ///     3 drawables, fullscreen:  80.1 fps, waitDrawable 12.3 ms
    ///
    /// One frame of latency against half the frame rate is not a close call.
    ///
    /// Three is also the ceiling. `CAMetalLayer` accepts 2 or 3 and nothing
    /// else, so the Space path cannot be pushed past 80 fps this way: the
    /// relationship measured exactly (N - 1) x 40 fps, and there is no N = 4.
    static let maxFramesInFlight = {
        if let v = ProcessInfo.processInfo.environment["VELO_FLIGHT"], let n = Int(v) {
            // Clamped hard. CAMetalLayer accepts 2 or 3 drawables and nothing
            // else, and a semaphore permitting more waits forever for a
            // drawable that cannot exist: at 4 the app renders no frames at all.
            return max(2, min(n, 3))
        }
        return 3
    }()

    let beatBus: BeatBus
    private(set) var syphon: SyphonOutput?

    private let device: MTLDevice
    private let queue: MTL4CommandQueue
    private let compiler: MTL4Compiler
    private var allocators: [MTL4CommandAllocator] = []
    private var commandBuffers: [MTL4CommandBuffer] = []
    /// Bindings, one table per pass per in-flight frame.
    ///
    /// A Metal 4 argument table is GPU-visible memory: the GPU reads the
    /// bindings when the pass *executes*, not when it is encoded. Sharing one
    /// table across the passes of a frame therefore makes every pass see the
    /// last writes — during a crossfade the outgoing scene sampled the incoming
    /// scene's data buffer, and since each scene reads that buffer to its own
    /// layout it drew garbage. Giving every pass its own table keeps each set
    /// of bindings intact until the GPU is finished with it.
    private var argumentTables: [[MTL4ArgumentTable]] = []

    /// Most passes in one frame: outgoing scene, incoming scene, mix, blit.
    private static let passesPerFrame = 4
    private var pipeline: MTLRenderPipelineState?
    private var library: MTLLibrary?
    private var pixelFormat: MTLPixelFormat = .bgra8Unorm
    private var blitPipeline: MTLRenderPipelineState?
    private var mixPipeline: MTLRenderPipelineState?
    private var lastOffscreenInResidency: MTLTexture?

    var transitionsEnabled: Bool = false
    var transitionDuration: Float = 10.0
    private var transitionStartTime: Float = -1
    private var transitioningFromScene: Int? = nil
    private var oldPipeline: MTLRenderPipelineState?
    private var oldPixelFormat: MTLPixelFormat?
    private var transitionTexture: MTLTexture?

    /// Metal 4 makes residency the app's job. A buffer that is not in a
    /// residency set attached to the queue reads as zeros on the GPU, with no
    /// error and no validation complaint. The small per-frame buffers happened
    /// to work without one, which is luck rather than correctness, and the
    /// first larger buffer a scene allocated came back empty.
    private var residencySet: MTLResidencySet?

    private var uniformBuffers: [MTLBuffer] = []
    private var bandBuffers: [MTLBuffer] = []
    private var oldBandBuffers: [MTLBuffer] = []
    private let frameSemaphore = DispatchSemaphore(value: maxFramesInFlight)
    private var frameIndex = 0
    private var lastTime: Float = -1

    /// Every scene, in switch order. Adding a visual is one line here plus one
    /// new file — the same shape as the Android catalogue.
    private let scenes: [VeloScene] = SceneCatalog.makeAll()
    private var sceneIndexStorage = 0
    private var pendingScene: Int?
    private let sceneLock = NSLock()

    /// Read from the UI, written from the render thread's caller.
    var sceneIndex: Int {
        get { sceneLock.lock(); defer { sceneLock.unlock() }; return sceneIndexStorage }
    }
    var sceneName: String { scenes[sceneIndex].name }
    var sceneNames: [String] { scenes.map(\.name) }

    /// Syphon output resolution. Defaults to 4K; the window can be any size.
    var syphonOutputWidth: Int = 3840
    var syphonOutputHeight: Int = 2160

    let stats = FrameStats()

    init?(device: MTLDevice, beatBus: BeatBus = .shared) {
        self.beatBus = beatBus
        guard let queue = device.makeMTL4CommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        guard let compiler = try? device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        else { return nil }
        self.compiler = compiler

        let allocDescriptor = MTL4CommandAllocatorDescriptor()
        for _ in 0..<Self.maxFramesInFlight {
            guard let a = try? device.makeCommandAllocator(descriptor: allocDescriptor),
                  let cb = device.makeCommandBuffer()
            else { return nil }
            allocators.append(a)
            commandBuffers.append(cb)
        }

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 4
        tableDescriptor.maxTextureBindCount = 4
        for _ in 0..<Self.maxFramesInFlight {
            var perPass: [MTL4ArgumentTable] = []
            for _ in 0..<Self.passesPerFrame {
                guard let t = try? device.makeArgumentTable(descriptor: tableDescriptor)
                else { return nil }
                perPass.append(t)
            }
            argumentTables.append(perPass)
        }

        for _ in 0..<Self.maxFramesInFlight {
            guard let u = device.makeBuffer(
                    length: MemoryLayout<Uniforms>.stride, options: .storageModeShared),
                  let b = device.makeBuffer(
                    length: SceneCatalog.sceneBufferBytes, options: .storageModeShared),
                  let ob = device.makeBuffer(
                    length: SceneCatalog.sceneBufferBytes, options: .storageModeShared)
            else { return nil }
            uniformBuffers.append(u)
            bandBuffers.append(b)
            oldBandBuffers.append(ob)
        }

        syphon = SyphonOutput(device: device)
        scenes.forEach { $0.prepare(device: device) }

        // Everything the shaders will ever read, made resident once. Scenes
        // allocate in prepare(), so this has to come after them.
        if let set = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor()) {
            uniformBuffers.forEach { set.addAllocation($0) }
            bandBuffers.forEach { set.addAllocation($0) }
            oldBandBuffers.forEach { set.addAllocation($0) }
            scenes.compactMap(\.historyBuffer).forEach { set.addAllocation($0) }
            set.commit()
            set.requestResidency()
            queue.addResidencySet(set)
            residencySet = set
        }

        guard buildPipeline(for: .bgra8Unorm) else { return nil }
    }

    private static func makeMixPipeline(
        device: MTLDevice, compiler: MTL4Compiler, format: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 pos [[position]]; float2 uv; };
        vertex V mixVert(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            V o; o.pos = float4(p * 2.0 - 1.0, 0, 1);
            o.uv = float2(p.x, 1.0 - p.y);
            return o;
        }
        struct MixUniforms {
            float2 resolution;
            float time;
            float dim;
            float hueShift;
            float saturation;
            float tintR;
            float tintG;
            float tintB;
            float mixAlpha;
        };
        fragment float4 mixFrag(V in [[stage_in]],
                                texture2d<float> tex [[texture(1)]],
                                constant MixUniforms &u [[buffer(0)]]) {
            constexpr sampler s(filter::linear);
            float4 color = tex.sample(s, in.uv);
            return float4(color.rgb * u.mixAlpha, u.mixAlpha);
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { return nil }
        let vd = MTL4LibraryFunctionDescriptor(); vd.name = "mixVert"; vd.library = lib
        let fd = MTL4LibraryFunctionDescriptor(); fd.name = "mixFrag"; fd.library = lib
        let desc = MTL4RenderPipelineDescriptor()
        desc.vertexFunctionDescriptor = vd
        desc.fragmentFunctionDescriptor = fd
        let att = desc.colorAttachments[0]
        att?.pixelFormat = format
        att?.blendingState = .enabled
        att?.sourceRGBBlendFactor = .one
        att?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att?.rgbBlendOperation = .add
        att?.sourceAlphaBlendFactor = .one
        att?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        att?.alphaBlendOperation = .add
        return try? compiler.makeRenderPipelineState(descriptor: desc)
    }

    /// A minimal render pipeline that samples a texture onto a fullscreen
    /// triangle. Used to scale the Syphon offscreen into the drawable.
    private static func makeBlitPipeline(
        device: MTLDevice, compiler: MTL4Compiler, format: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 pos [[position]]; float2 uv; };
        vertex V blitVert(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            V o; o.pos = float4(p * 2.0 - 1.0, 0, 1);
            o.uv = float2(p.x, 1.0 - p.y);
            return o;
        }
        fragment float4 blitFrag(V in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear);
            return tex.sample(s, in.uv);
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { return nil }
        let vd = MTL4LibraryFunctionDescriptor(); vd.name = "blitVert"; vd.library = lib
        let fd = MTL4LibraryFunctionDescriptor(); fd.name = "blitFrag"; fd.library = lib
        let desc = MTL4RenderPipelineDescriptor()
        desc.vertexFunctionDescriptor = vd
        desc.fragmentFunctionDescriptor = fd
        desc.colorAttachments[0]?.pixelFormat = format
        return try? compiler.makeRenderPipelineState(descriptor: desc)
    }

    /// Switch scenes. Each carries its own shader, so this recompiles: a few
    /// milliseconds, once, on a keypress. Cheaper than keeping every pipeline
    /// resident for visuals that may never be shown.
    ///
    /// Only REQUESTS the switch. It used to move the index here and rebuild the
    /// pipeline on the caller's thread, which is the main thread, while the
    /// render thread was mid-frame. Two things went wrong in that window: the
    /// render thread read the new scene's data through the old scene's shader,
    /// which interprets the buffer as a completely different struct and draws
    /// garbage, and `pipeline` itself was reassigned underneath a thread that
    /// was using it. That was the flash of distortion when stepping through
    /// visuals with the arrow keys.
    ///
    /// The render thread now performs the swap between frames, where it is the
    /// only thread touching either, and builds the pipeline BEFORE moving the
    /// index so the two can never disagree.
    func selectScene(_ index: Int) {
        let clamped = ((index % scenes.count) + scenes.count) % scenes.count
        sceneLock.lock()
        if clamped != sceneIndexStorage { pendingScene = clamped }
        sceneLock.unlock()
    }

    /// Apply a requested scene change. Render thread only.
    private func applyPendingScene(time: Float) {
        sceneLock.lock()
        let target = pendingScene
        pendingScene = nil
        sceneLock.unlock()
        guard let target, target != sceneIndexStorage else { return }

        if transitionsEnabled && pipeline != nil {
            transitioningFromScene = sceneIndexStorage
            oldPipeline = pipeline
            oldPixelFormat = pixelFormat
            transitionStartTime = time
        } else {
            transitioningFromScene = nil
            oldPipeline = nil
            releaseTransitionTexture()
        }

        // Build first, swap second. A failed compile leaves the current scene
        // running rather than presenting a black canvas.
        let previous = sceneIndexStorage
        sceneLock.lock(); sceneIndexStorage = target; sceneLock.unlock()
        library = nil
        if !buildPipeline(for: pixelFormat, force: true) {
            sceneLock.lock(); sceneIndexStorage = previous; sceneLock.unlock()
            library = nil
            _ = buildPipeline(for: pixelFormat, force: true)
            transitioningFromScene = nil
            oldPipeline = nil
        }
    }

    /// The scratch texture the incoming scene is drawn into during a crossfade.
    ///
    /// Reused for as long as it stays compatible with the target. The format
    /// has to match as well as the size: the incoming scene is drawn with the
    /// live pipeline, and a pipeline's colour attachment format must equal the
    /// texture it renders into, so an HDR toggle at an unchanged size still
    /// needs a new texture. Replacing one also drops the old allocation from
    /// the residency set, which otherwise accumulated a full-size texture per
    /// transition for the lifetime of the process.
    private func ensureTransitionTexture(matching target: MTLTexture) {
        if let t = transitionTexture,
           t.width == target.width,
           t.height == target.height,
           t.pixelFormat == target.pixelFormat {
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: target.pixelFormat,
            width: target.width, height: target.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private

        guard let fresh = device.makeTexture(descriptor: desc) else { return }
        if let old = transitionTexture { residencySet?.removeAllocation(old) }
        transitionTexture = fresh
        residencySet?.addAllocation(fresh)
        residencySet?.commit()
        residencySet?.requestResidency()
    }

    /// Drop the crossfade scratch texture and its residency entry.
    private func releaseTransitionTexture() {
        guard let old = transitionTexture else { return }
        residencySet?.removeAllocation(old)
        residencySet?.commit()
        transitionTexture = nil
    }

    func cycleScene(_ delta: Int) { selectScene(sceneIndex + delta) }

    /// The colour attachment format has to match the layer's, so a HDR toggle
    /// means a new pipeline. Cheap enough to do on demand and it avoids keeping
    /// two pipelines alive for a format that may never be used.
    @discardableResult
    func buildPipeline(for format: MTLPixelFormat, force: Bool = false) -> Bool {
        if !force, pixelFormat == format, pipeline != nil { return true }
        if mixPipeline == nil || pixelFormat != format {
            mixPipeline = Self.makeMixPipeline(device: device, compiler: compiler, format: format)
            blitPipeline = Self.makeBlitPipeline(device: device, compiler: compiler, format: format)
        }
        if library == nil {
            do {
                library = try device.makeLibrary(
                    source: scenes[sceneIndex].shaderSource, options: nil)
            } catch {
                // Shaders are compiled at runtime, so a syntax error would
                // otherwise present as a silently black canvas.
                print("[velo] SHADER FAILED (\(scenes[sceneIndex].name)): \(error)")
                fflush(stdout)
                return false
            }
        }
        guard let library else { return false }

        let vertexDescriptor = MTL4LibraryFunctionDescriptor()
        vertexDescriptor.name = "veloVertex"
        vertexDescriptor.library = library
        let fragmentDescriptor = MTL4LibraryFunctionDescriptor()
        fragmentDescriptor.name = "veloFragment"
        fragmentDescriptor.library = library

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.vertexFunctionDescriptor = vertexDescriptor
        descriptor.fragmentFunctionDescriptor = fragmentDescriptor

        guard let attachment = descriptor.colorAttachments[0] else { return false }
        attachment.pixelFormat = format
        if scenes[sceneIndex].draw.additive {
            attachment.blendingState = .enabled
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.rgbBlendOperation = .add
            // Leave the cleared alpha alone. The layer is opaque, and on a float
            // HDR format an accumulating alpha is not clamped for us.
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
        }

        let state: MTLRenderPipelineState
        do {
            state = try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[velo] PIPELINE FAILED (\(scenes[sceneIndex].name)): \(error)")
            fflush(stdout)
            return false
        }
        pipeline = state
        pixelFormat = format
        return true
    }

    /// Draw one frame into a texture and wait for it. For `SelfTest` only:
    /// same encode path as `render`, minus the drawable and the pacing.
    @discardableResult
    func renderOffscreen(into target: MTLTexture, audio: AudioEngine, time: Float) -> Double {
        applyPendingScene(time: time)
        guard buildPipeline(for: target.pixelFormat), let pipeline else { return 0 }
        let slot = frameIndex % Self.maxFramesInFlight
        frameIndex &+= 1

        let scene = scenes[sceneIndex]
        beatBus.update(audio: audio, dt: 1.0 / 60.0, time: time)
        BeatBus.current = beatBus
        scene.update(audio: audio, dt: 1.0 / 60.0)

        let theme = ThemePreset.current.grade
        var uniforms = Uniforms(
            resolution: SIMD2(Float(target.width), Float(target.height)),
            time: time, dim: 1,
            hueShift: theme.hueShift, saturation: theme.saturation,
            tintR: theme.tintR, tintG: theme.tintG, tintB: theme.tintB)
        uniformBuffers[slot].contents()
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)
        scene.writeData(into: bandBuffers[slot].contents())

        let allocator = allocators[slot]
        let commandBuffer = commandBuffers[slot]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            let table = argumentTables[slot][0]
            encoder.setRenderPipelineState(pipeline)
            table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
            table.setAddress(bandBuffers[slot].gpuAddress, index: 1)
            if let history = scene.historyBuffer {
                table.setAddress(history.gpuAddress, index: 2)
            }
            encoder.setArgumentTable(table, stages: .fragment)
            encoder.setArgumentTable(table, stages: .vertex)
            let draw = scene.draw
            encoder.drawPrimitives(
                primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
            encoder.endEncoding()
        }
        commandBuffer.endCommandBuffer()

        // Metal's own timestamps, so the figure is GPU execution and not our
        // wait for it.
        let done = DispatchSemaphore(value: 0)
        let elapsed = TimingBox()
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { feedback in
            elapsed.seconds = feedback.gpuEndTime - feedback.gpuStartTime
            done.signal()
        }
        queue.commit([commandBuffer], options: options)
        done.wait()
        return elapsed.seconds
    }

    func render(layer: CAMetalLayer, audio: AudioEngine, time: Float) {
        applyPendingScene(time: time)
        guard let pipeline else { return }

        // ORDER MATTERS. Throttle on our own resources first, then ask for a
        // drawable. Doing it the other way round blocks inside nextDrawable()
        // before there is any chance to bail, and holds the display-link thread
        // for as long as the GPU is behind.
        // Time the BLOCKING separately. Measuring only after acquisition hides
        // exactly the stall we are hunting: both of these can park the
        // display-link thread for milliseconds without showing up as GPU work.
        let waitStart = CACurrentMediaTime()
        frameSemaphore.wait()
        let semaphoreWait = CACurrentMediaTime() - waitStart

        let acquireStart = CACurrentMediaTime()
        guard let drawable = layer.nextDrawable() else {
            frameSemaphore.signal()
            stats.recordDropped()
            return
        }
        let acquireWait = CACurrentMediaTime() - acquireStart
        stats.recordWaits(semaphore: semaphoreWait, drawable: acquireWait)

        let encodeStart = CACurrentMediaTime()
        let slot = frameIndex % Self.maxFramesInFlight
        frameIndex &+= 1

        let dt = lastTime < 0 ? 1.0 / 120.0 : min(max(time - lastTime, 0), 0.1)
        lastTime = time
        beatBus.update(audio: audio, dt: dt, time: time)
        BeatBus.current = beatBus
        
        let transitionProgress: Float
        if transitioningFromScene != nil, transitionStartTime > 0, oldPipeline != nil {
            transitionProgress = min(max((time - transitionStartTime) / transitionDuration, 0.0), 1.0)
            if transitionProgress >= 1.0 {
                // The scratch texture is kept for the next crossfade rather
                // than freed: re-allocating a full-size target on every scene
                // change is wasteful, and it is released outright when
                // transitions are switched off.
                transitioningFromScene = nil
                oldPipeline = nil
            }
        } else {
            transitionProgress = 1.0
        }

        let scene = scenes[sceneIndex]
        scene.update(audio: audio, dt: dt)
        
        if transitionProgress < 1.0, let oldIndex = transitioningFromScene {
            scenes[oldIndex].update(audio: audio, dt: dt)
        }

        // When Syphon is active, render to a fixed-size offscreen texture
        // (default 3840x2160) and blit to the drawable. This eliminates
        // tearing (the offscreen is not framebufferOnly and not recycled)
        // and gives Syphon clients a stable 4K feed regardless of window
        // size. When Syphon is off, render directly to the drawable.
        let syphonActive = syphon?.isRunning == true
        let renderTarget: MTLTexture
        let syphonTexture: MTLTexture?

        if syphonActive,
           let offscreen = syphon?.ensureOffscreen(
               width: syphonOutputWidth, height: syphonOutputHeight) {
            if offscreen !== lastOffscreenInResidency, let set = residencySet {
                set.addAllocation(offscreen)
                set.commit()
                set.requestResidency()
                lastOffscreenInResidency = offscreen
            }
            renderTarget = offscreen
            syphonTexture = offscreen
        } else {
            renderTarget = drawable.texture
            syphonTexture = nil
        }

        if transitionProgress < 1.0 {
            ensureTransitionTexture(matching: renderTarget)
        }

        let theme = ThemePreset.current.grade
        var uniforms = Uniforms(
            resolution: SIMD2(Float(renderTarget.width), Float(renderTarget.height)),
            time: time,
            dim: 1,
            hueShift: theme.hueShift,
            saturation: theme.saturation,
            tintR: theme.tintR,
            tintG: theme.tintG,
            tintB: theme.tintB,
            mixAlpha: transitionProgress
        )
        uniformBuffers[slot].contents()
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        scene.writeData(into: bandBuffers[slot].contents())
        if transitionProgress < 1.0, let oldIndex = transitioningFromScene {
            scenes[oldIndex].writeData(into: oldBandBuffers[slot].contents())
        }

        let allocator = allocators[slot]
        let commandBuffer = commandBuffers[slot]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        if transitionProgress < 1.0, let oldIndex = transitioningFromScene, let oldPSO = oldPipeline, let tTex = transitionTexture {
            let oldScene = scenes[oldIndex]
            
            // Render old scene to renderTarget
            let oldPass = MTL4RenderPassDescriptor()
            oldPass.colorAttachments[0].texture = renderTarget
            oldPass.colorAttachments[0].loadAction = .clear
            oldPass.colorAttachments[0].storeAction = .store
            oldPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: oldPass) {
                let table = argumentTables[slot][0]
                encoder.setRenderPipelineState(oldPSO)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setAddress(oldBandBuffers[slot].gpuAddress, index: 1)
                if let history = oldScene.historyBuffer {
                    table.setAddress(history.gpuAddress, index: 2)
                }
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.setArgumentTable(table, stages: .vertex)
                let draw = oldScene.draw
                encoder.drawPrimitives(
                    primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
                encoder.endEncoding()
            }

            // Render new scene to transitionTexture
            let newPass = MTL4RenderPassDescriptor()
            newPass.colorAttachments[0].texture = tTex
            newPass.colorAttachments[0].loadAction = .clear
            newPass.colorAttachments[0].storeAction = .store
            newPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: newPass) {
                let table = argumentTables[slot][1]
                encoder.setRenderPipelineState(pipeline)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setAddress(bandBuffers[slot].gpuAddress, index: 1)
                if let history = scene.historyBuffer {
                    table.setAddress(history.gpuAddress, index: 2)
                }
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.setArgumentTable(table, stages: .vertex)
                let draw = scene.draw
                encoder.drawPrimitives(
                    primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
                encoder.endEncoding()
            }

            // Mix transitionTexture over renderTarget
            let mixPass = MTL4RenderPassDescriptor()
            mixPass.colorAttachments[0].texture = renderTarget
            mixPass.colorAttachments[0].loadAction = .load
            mixPass.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: mixPass), let mixPSO = mixPipeline {
                // This pass samples the texture the incoming-scene pass just
                // wrote, and blends over the target the outgoing-scene pass
                // wrote. Metal 4 does not track those hazards, so without
                // waiting we sample tiles the GPU is still writing — seen as
                // sparkle around high-contrast detail like Aurora Drift's
                // stars and Nebula's bright cores.
                encoder.barrier(afterQueueStages: .fragment,
                                beforeStages: .fragment,
                                visibilityOptions: .device)
                let table = argumentTables[slot][2]
                encoder.setRenderPipelineState(mixPSO)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setTexture(tTex.gpuResourceID, index: 1)
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.drawPrimitives(
                    primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        } else {
            // Normal render
            let pass = MTL4RenderPassDescriptor()
            pass.colorAttachments[0].texture = renderTarget
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                let table = argumentTables[slot][0]
                encoder.setRenderPipelineState(pipeline)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setAddress(bandBuffers[slot].gpuAddress, index: 1)
                if let history = scene.historyBuffer {
                    table.setAddress(history.gpuAddress, index: 2)
                }
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.setArgumentTable(table, stages: .vertex)
                let draw = scene.draw
                encoder.drawPrimitives(
                    primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
                encoder.endEncoding()
            }
        }

        // 2) If we rendered offscreen, scale-blit into the drawable via a
        //    fullscreen-triangle render pass. BlitEncoder.copy() can't scale.
        if syphonTexture != nil, let blitPSO = blitPipeline {
            let blitPass = MTL4RenderPassDescriptor()
            blitPass.colorAttachments[0].texture = drawable.texture
            blitPass.colorAttachments[0].loadAction = .dontCare
            blitPass.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: blitPass) {
                // Same hazard again: this samples the offscreen the scene (or
                // mix) pass just rendered into. Unlike the mix barrier this one
                // applies whenever Syphon is on, transition or not.
                encoder.barrier(afterQueueStages: .fragment,
                                beforeStages: .fragment,
                                visibilityOptions: .device)
                let table = argumentTables[slot][3]
                encoder.setRenderPipelineState(blitPSO)
                table.setTexture(renderTarget.gpuResourceID, index: 0)
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.drawPrimitives(
                    primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        commandBuffer.endCommandBuffer()

        let options = MTL4CommitOptions()
        let stats = stats
        let semaphore = frameSemaphore
        let syphonTexWrapper = SendableTexture(texture: syphonTexture)
        let syphonInst = syphon
        options.addFeedbackHandler { [syphonTexWrapper, syphonInst] feedback in
            stats.recordGPU(feedback.gpuEndTime - feedback.gpuStartTime)
            if let tex = syphonTexWrapper.texture {
                syphonInst?.publish(texture: tex)
            }
            semaphore.signal()
        }

        queue.waitForDrawable(drawable)
        queue.commit([commandBuffer], options: options)

        queue.signalDrawable(drawable)
        drawable.present()

        stats.recordFrame(
            encode: CACurrentMediaTime() - encodeStart,
            size: renderTarget.width * renderTarget.height
        )
    }
    /// Headless render for Syphon-only mode: renders to the offscreen texture
    /// and publishes to Syphon clients. No drawable is acquired or presented,
    /// so the window can show a control panel instead of the canvas.
    func renderSyphonOnly(audio: AudioEngine, time: Float) {
        applyPendingScene(time: time)
        guard buildPipeline(for: .bgra8Unorm), let pipeline else { return }
        guard let syphon, syphon.isRunning,
              let offscreen = syphon.ensureOffscreen(
                  width: syphonOutputWidth, height: syphonOutputHeight)
        else { return }

        if offscreen !== lastOffscreenInResidency, let set = residencySet {
            set.addAllocation(offscreen)
            set.commit()
            set.requestResidency()
            lastOffscreenInResidency = offscreen
        }

        frameSemaphore.wait()
        let encodeStart = CACurrentMediaTime()
        let slot = frameIndex % Self.maxFramesInFlight
        frameIndex &+= 1

        let dt = lastTime < 0 ? 1.0 / 60.0 : min(max(time - lastTime, 0), 0.1)
        lastTime = time
        beatBus.update(audio: audio, dt: dt, time: time)
        let transitionProgress: Float
        if transitioningFromScene != nil, transitionStartTime > 0, oldPipeline != nil {
            transitionProgress = min(max((time - transitionStartTime) / transitionDuration, 0.0), 1.0)
            if transitionProgress >= 1.0 {
                // The scratch texture is kept for the next crossfade rather
                // than freed: re-allocating a full-size target on every scene
                // change is wasteful, and it is released outright when
                // transitions are switched off.
                transitioningFromScene = nil
                oldPipeline = nil
            }
        } else {
            transitionProgress = 1.0
        }

        let scene = scenes[sceneIndex]
        scene.update(audio: audio, dt: dt)
        
        if transitionProgress < 1.0, let oldIndex = transitioningFromScene {
            scenes[oldIndex].update(audio: audio, dt: dt)
        }

        if transitionProgress < 1.0 {
            ensureTransitionTexture(matching: offscreen)
        }

        let theme = ThemePreset.current.grade
        var uniforms = Uniforms(
            resolution: SIMD2(Float(offscreen.width), Float(offscreen.height)),
            time: time, dim: 1,
            hueShift: theme.hueShift, saturation: theme.saturation,
            tintR: theme.tintR, tintG: theme.tintG, tintB: theme.tintB,
            mixAlpha: transitionProgress)
        uniformBuffers[slot].contents()
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)
            
        scene.writeData(into: bandBuffers[slot].contents())
        if transitionProgress < 1.0, let oldIndex = transitioningFromScene {
            scenes[oldIndex].writeData(into: oldBandBuffers[slot].contents())
        }

        let allocator = allocators[slot]
        let commandBuffer = commandBuffers[slot]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        if transitionProgress < 1.0, let oldIndex = transitioningFromScene, let oldPSO = oldPipeline, let tTex = transitionTexture {
            let oldScene = scenes[oldIndex]
            
            // Render old scene
            let oldPass = MTL4RenderPassDescriptor()
            oldPass.colorAttachments[0].texture = offscreen
            oldPass.colorAttachments[0].loadAction = .clear
            oldPass.colorAttachments[0].storeAction = .store
            oldPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: oldPass) {
                let table = argumentTables[slot][0]
                encoder.setRenderPipelineState(oldPSO)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setAddress(oldBandBuffers[slot].gpuAddress, index: 1)
                if let history = oldScene.historyBuffer {
                    table.setAddress(history.gpuAddress, index: 2)
                }
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.setArgumentTable(table, stages: .vertex)
                let draw = oldScene.draw
                encoder.drawPrimitives(
                    primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
                encoder.endEncoding()
            }

            // Render new scene
            let newPass = MTL4RenderPassDescriptor()
            newPass.colorAttachments[0].texture = tTex
            newPass.colorAttachments[0].loadAction = .clear
            newPass.colorAttachments[0].storeAction = .store
            newPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: newPass) {
                let table = argumentTables[slot][1]
                encoder.setRenderPipelineState(pipeline)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setAddress(bandBuffers[slot].gpuAddress, index: 1)
                if let history = scene.historyBuffer {
                    table.setAddress(history.gpuAddress, index: 2)
                }
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.setArgumentTable(table, stages: .vertex)
                let draw = scene.draw
                encoder.drawPrimitives(
                    primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
                encoder.endEncoding()
            }

            // Mix
            let mixPass = MTL4RenderPassDescriptor()
            mixPass.colorAttachments[0].texture = offscreen
            mixPass.colorAttachments[0].loadAction = .load
            mixPass.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: mixPass), let mixPSO = mixPipeline {
                // This pass samples the texture the incoming-scene pass just
                // wrote, and blends over the target the outgoing-scene pass
                // wrote. Metal 4 does not track those hazards, so without
                // waiting we sample tiles the GPU is still writing — seen as
                // sparkle around high-contrast detail like Aurora Drift's
                // stars and Nebula's bright cores.
                encoder.barrier(afterQueueStages: .fragment,
                                beforeStages: .fragment,
                                visibilityOptions: .device)
                let table = argumentTables[slot][2]
                encoder.setRenderPipelineState(mixPSO)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setTexture(tTex.gpuResourceID, index: 1)
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.drawPrimitives(
                    primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        } else {
            let pass = MTL4RenderPassDescriptor()
            pass.colorAttachments[0].texture = offscreen
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                let table = argumentTables[slot][0]
                encoder.setRenderPipelineState(pipeline)
                table.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
                table.setAddress(bandBuffers[slot].gpuAddress, index: 1)
                if let history = scene.historyBuffer {
                    table.setAddress(history.gpuAddress, index: 2)
                }
                encoder.setArgumentTable(table, stages: .fragment)
                encoder.setArgumentTable(table, stages: .vertex)
                let draw = scene.draw
                encoder.drawPrimitives(
                    primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
                encoder.endEncoding()
            }
        }

        commandBuffer.endCommandBuffer()

        let options = MTL4CommitOptions()
        let stats = stats
        let semaphore = frameSemaphore
        let offscreenWrapper = SendableTexture(texture: offscreen)
        options.addFeedbackHandler { [syphon, offscreenWrapper] feedback in
            stats.recordGPU(feedback.gpuEndTime - feedback.gpuStartTime)
            if let tex = offscreenWrapper.texture {
                syphon.publish(texture: tex)
            }
            semaphore.signal()
        }
        queue.commit([commandBuffer], options: options)

        stats.recordFrame(
            encode: CACurrentMediaTime() - encodeStart,
            size: offscreen.width * offscreen.height)
    }
}

/// Carries one GPU timing out of the feedback handler. The handler is
/// `@Sendable`, and the caller is blocked on the semaphore until it fires, so
/// the two never touch this at the same time.
private final class TimingBox: @unchecked Sendable {
    var seconds: Double = 0
}

/// Frame timing, summarised to stdout.
///
/// Exists because "it feels laggy in fullscreen" is not something that can be
/// reasoned about from a source file: the question is whether frames are being
/// dropped, whether the CPU is late, or whether the GPU simply cannot fill that
/// many pixels — and those have completely different fixes.
final class FrameStats: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [Double] = []
    private var encodes: [Double] = []
    private var semWaits: [Double] = []
    private var drawWaits: [Double] = []
    private var linkInterval: Double = 0
    private var gpuTimes: [Double] = []
    private var dropped = 0
    private var lastFrame: Double = 0
    private var lastReport: Double = CACurrentMediaTime()
    private var pixels = 0

    /// Printing to stdout is opt-in. COLLECTING is not: the overlay needs the
    /// numbers, and appending a few doubles per frame costs nothing next to a
    /// frame of rendering.
    var printing = ProcessInfo.processInfo.environment["VELO_STATS"] != nil

    private var current = PerfSnapshot()
    private var lastSample: Double = CACurrentMediaTime()

    /// The most recent reading. Safe to poll from any thread.
    var snapshot: PerfSnapshot {
        lock.lock(); defer { lock.unlock() }; return current
    }

    func recordDropped() {
        lock.lock(); dropped += 1; lock.unlock()
    }

    private func mean(_ v: [Double]) -> Double {
        v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    /// The display link's OWN expected frame duration. If this reads 8.3 ms
    /// the panel is at 120 Hz and we are missing callbacks; if it reads 12.5 ms
    /// the system is simply calling us at 80 Hz. Those need opposite fixes.
    func recordLinkInterval(_ seconds: Double) {
        lock.lock(); linkInterval = seconds; lock.unlock()
    }

    func recordWaits(semaphore: Double, drawable: Double) {
        lock.lock(); semWaits.append(semaphore); drawWaits.append(drawable); lock.unlock()
    }

    func recordGPU(_ seconds: Double) {
        lock.lock(); gpuTimes.append(seconds); lock.unlock()
    }

    func recordFrame(encode: Double, size: Int) {
        let now = CACurrentMediaTime()
        lock.lock()
        if lastFrame > 0 { intervals.append(now - lastFrame) }
        lastFrame = now
        encodes.append(encode)
        pixels = size
        // Two cadences from one set of buffers. The overlay wants to feel
        // live, and a log line every quarter second is unreadable.
        let sampling = now - lastSample >= 0.25
        let due = now - lastReport >= 2.0
        if sampling {
            lastSample = now
            if !intervals.isEmpty {
                current = PerfSnapshot(
                    fps: 1.0 / (intervals.reduce(0, +) / Double(intervals.count)),
                    worstMs: (intervals.max() ?? 0) * 1000,
                    gpuMs: mean(gpuTimes) * 1000,
                    encodeMs: mean(encodes) * 1000,
                    waitDrawableMs: mean(drawWaits) * 1000,
                    waitSemaphoreMs: mean(semWaits) * 1000,
                    dropped: dropped,
                    hitches: intervals.filter { $0 > 0.05 }.count,
                    pixels: size,
                    displayHz: linkInterval > 0 ? 1.0 / linkInterval : 0
                )
            }
        }
        if due { lastReport = now }
        let snapshotIntervals = due ? intervals : []
        let snapshotEncodes = due ? encodes : []
        let snapshotGPU = due ? gpuTimes : []
        let snapshotDropped = due ? dropped : 0
        let snapshotPixels = pixels
        let snapshotSem = due ? semWaits : []
        // How MANY long frames, not just the worst. One 268 ms stall per
        // report and a steady drizzle of them are different faults, and the
        // maximum alone cannot tell them apart.
        let snapshotHitches = due ? intervals.filter({ $0 > 0.05 }).count : 0
        let snapshotDraw = due ? drawWaits : []
        let snapshotLink = linkInterval
        if due {
            intervals.removeAll(); encodes.removeAll(); gpuTimes.removeAll(); dropped = 0
            semWaits.removeAll(); drawWaits.removeAll()
        }
        lock.unlock()

        guard printing, due, !snapshotIntervals.isEmpty else { return }
        // Formatting and writing on the render thread perturbs the very timing
        // being measured — it showed up as a ~260 ms hitch once per reporting
        // period. Hand it to a background queue.
        DispatchQueue.global(qos: .utility).async {
        let fps = 1.0 / (snapshotIntervals.reduce(0, +) / Double(snapshotIntervals.count))
        let worst = (snapshotIntervals.max() ?? 0) * 1000
        let encodeMs = (snapshotEncodes.reduce(0, +) / Double(snapshotEncodes.count)) * 1000
        let gpuMs = snapshotGPU.isEmpty
            ? 0 : (snapshotGPU.reduce(0, +) / Double(snapshotGPU.count)) * 1000
        let semMs = snapshotSem.isEmpty
            ? 0 : (snapshotSem.reduce(0, +) / Double(snapshotSem.count)) * 1000
        let drawMs = snapshotDraw.isEmpty
            ? 0 : (snapshotDraw.reduce(0, +) / Double(snapshotDraw.count)) * 1000
        print(String(
            format: "[velo] %.1f fps  link %.2f ms  waitSem %.2f ms  waitDrawable %.2f ms  "
                + "encode %.2f ms  gpu %.2f ms  worst %.1f  dropped %d  %d px",
            fps, snapshotLink * 1000, semMs, drawMs, encodeMs, gpuMs,
            worst, snapshotDropped, snapshotPixels) + "  hitches \(snapshotHitches)")
        fflush(stdout)
        }
    }
}

private struct SendableTexture: @unchecked Sendable {
    let texture: MTLTexture?
}
