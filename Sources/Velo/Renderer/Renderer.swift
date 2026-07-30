import Foundation
import Metal
import QuartzCore
import simd

/// Per-frame values handed to the shader. Must match `Uniforms` in the MSL
/// source exactly.
struct Uniforms {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var dim: Float = 1
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
    private var argumentTable: MTL4ArgumentTable
    private var pipeline: MTLRenderPipelineState?
    private var library: MTLLibrary?
    private var pixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Metal 4 makes residency the app's job. A buffer that is not in a
    /// residency set attached to the queue reads as zeros on the GPU, with no
    /// error and no validation complaint. The small per-frame buffers happened
    /// to work without one, which is luck rather than correctness, and the
    /// first larger buffer a scene allocated came back empty.
    private var residencySet: MTLResidencySet?

    private var uniformBuffers: [MTLBuffer] = []
    private var bandBuffers: [MTLBuffer] = []
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
        guard let table = try? device.makeArgumentTable(descriptor: tableDescriptor)
        else { return nil }
        self.argumentTable = table

        for _ in 0..<Self.maxFramesInFlight {
            guard let u = device.makeBuffer(
                    length: MemoryLayout<Uniforms>.stride, options: .storageModeShared),
                  let b = device.makeBuffer(
                    length: SceneCatalog.sceneBufferBytes, options: .storageModeShared)
            else { return nil }
            uniformBuffers.append(u)
            bandBuffers.append(b)
        }

        syphon = SyphonOutput(device: device)
        scenes.forEach { $0.prepare(device: device) }

        // Everything the shaders will ever read, made resident once. Scenes
        // allocate in prepare(), so this has to come after them.
        if let set = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor()) {
            uniformBuffers.forEach { set.addAllocation($0) }
            bandBuffers.forEach { set.addAllocation($0) }
            scenes.compactMap(\.historyBuffer).forEach { set.addAllocation($0) }
            set.commit()
            set.requestResidency()
            queue.addResidencySet(set)
            residencySet = set
        }

        guard buildPipeline(for: .bgra8Unorm) else { return nil }
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
    private func applyPendingScene() {
        sceneLock.lock()
        let target = pendingScene
        pendingScene = nil
        sceneLock.unlock()
        guard let target, target != sceneIndexStorage else { return }

        // Build first, swap second. A failed compile leaves the current scene
        // running rather than presenting a black canvas.
        let previous = sceneIndexStorage
        sceneLock.lock(); sceneIndexStorage = target; sceneLock.unlock()
        library = nil
        if !buildPipeline(for: pixelFormat, force: true) {
            sceneLock.lock(); sceneIndexStorage = previous; sceneLock.unlock()
            library = nil
            _ = buildPipeline(for: pixelFormat, force: true)
        }
    }

    func cycleScene(_ delta: Int) { selectScene(sceneIndex + delta) }

    /// The colour attachment format has to match the layer's, so a HDR toggle
    /// means a new pipeline. Cheap enough to do on demand and it avoids keeping
    /// two pipelines alive for a format that may never be used.
    @discardableResult
    func buildPipeline(for format: MTLPixelFormat, force: Bool = false) -> Bool {
        if !force, pixelFormat == format, pipeline != nil { return true }
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

        guard let state = try? compiler.makeRenderPipelineState(descriptor: descriptor)
        else {
            print("[velo] PIPELINE FAILED (\(scenes[sceneIndex].name))")
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
        applyPendingScene()
        guard buildPipeline(for: target.pixelFormat), let pipeline else { return 0 }
        let slot = frameIndex % Self.maxFramesInFlight
        frameIndex &+= 1

        let scene = scenes[sceneIndex]
        beatBus.update(audio: audio, dt: 1.0 / 60.0, time: time)
        BeatBus.current = beatBus
        scene.update(audio: audio, dt: 1.0 / 60.0)

        var uniforms = Uniforms(
            resolution: SIMD2(Float(target.width), Float(target.height)),
            time: time, dim: 1)
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
            encoder.setRenderPipelineState(pipeline)
            argumentTable.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
            argumentTable.setAddress(bandBuffers[slot].gpuAddress, index: 1)
            if let history = scene.historyBuffer {
                argumentTable.setAddress(history.gpuAddress, index: 2)
            }
            encoder.setArgumentTable(argumentTable, stages: .fragment)
            encoder.setArgumentTable(argumentTable, stages: .vertex)
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
        applyPendingScene()
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
        let scene = scenes[sceneIndex]
        scene.update(audio: audio, dt: dt)

        var uniforms = Uniforms(
            resolution: SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
            time: time,
            dim: 1
        )
        uniformBuffers[slot].contents()
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        scene.writeData(into: bandBuffers[slot].contents())

        let allocator = allocators[slot]
        let commandBuffer = commandBuffers[slot]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            argumentTable.setAddress(uniformBuffers[slot].gpuAddress, index: 0)
            argumentTable.setAddress(bandBuffers[slot].gpuAddress, index: 1)
            if let history = scene.historyBuffer {
                argumentTable.setAddress(history.gpuAddress, index: 2)
            }
            encoder.setArgumentTable(argumentTable, stages: .fragment)
            encoder.setArgumentTable(argumentTable, stages: .vertex)
            // Shader-generated vertices, no vertex buffer: three for a
            // fullscreen triangle (no seam down the diagonal a two-triangle
            // quad would have), or one per particle for a point-sprite scene.
            let draw = scene.draw
            encoder.drawPrimitives(
                primitiveType: draw.primitive, vertexStart: 0, vertexCount: draw.vertexCount)
            encoder.endEncoding()
        }
        commandBuffer.endCommandBuffer()

        let options = MTL4CommitOptions()
        let semaphore = frameSemaphore
        let stats = stats
        options.addFeedbackHandler { feedback in
            // TRUE GPU execution, from Metal's own timestamps. Timing the
            // handler against a CPU clock instead measures scheduling and vsync
            // waiting as well, which cannot distinguish "the GPU is slow" from
            // "we are simply being called less often" — the exact question here.
            stats.recordGPU(feedback.gpuEndTime - feedback.gpuStartTime)
            semaphore.signal()
        }

        queue.waitForDrawable(drawable)
        queue.commit([commandBuffer], options: options)
        syphon?.publish(texture: drawable.texture)
        queue.signalDrawable(drawable)
        drawable.present()

        stats.recordFrame(
            encode: CACurrentMediaTime() - encodeStart,
            size: drawable.texture.width * drawable.texture.height
        )
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
