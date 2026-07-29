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
    /// Two rather than three deliberately. A third drawable buys smoothness
    /// when the GPU occasionally overruns the vsync interval, and costs a whole
    /// frame of presentation latency to do it — 8.3 ms at 120 Hz, on every
    /// frame, forever. The GPU here runs 0.7-3.4 ms against an 8.3 ms budget,
    /// so there is no overrun to absorb and the third frame is pure delay.
    static let maxFramesInFlight = 2

    private let device: MTLDevice
    private let queue: MTL4CommandQueue
    private let compiler: MTL4Compiler
    private var allocators: [MTL4CommandAllocator] = []
    private var commandBuffers: [MTL4CommandBuffer] = []
    private var argumentTable: MTL4ArgumentTable
    private var pipeline: MTLRenderPipelineState?
    private var library: MTLLibrary?
    private var pixelFormat: MTLPixelFormat = .bgra8Unorm

    private var uniformBuffers: [MTLBuffer] = []
    private var bandBuffers: [MTLBuffer] = []
    private let frameSemaphore = DispatchSemaphore(value: maxFramesInFlight)
    private var frameIndex = 0
    private var lastTime: Float = -1

    /// Every scene, in switch order. Adding a visual is one line here plus one
    /// new file — the same shape as the Android catalogue.
    private let scenes: [VeloScene] = SceneCatalog.makeAll()
    private var sceneIndexStorage = 0
    private let sceneLock = NSLock()

    /// Read from the UI, written from the render thread's caller.
    var sceneIndex: Int {
        get { sceneLock.lock(); defer { sceneLock.unlock() }; return sceneIndexStorage }
    }
    var sceneName: String { scenes[sceneIndex].name }
    var sceneNames: [String] { scenes.map(\.name) }

    let stats = FrameStats()

    init?(device: MTLDevice) {
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

        scenes.forEach { $0.prepare(device: device) }
        guard buildPipeline(for: .bgra8Unorm) else { return nil }
    }

    /// Switch scenes. Each carries its own shader, so this recompiles — a few
    /// milliseconds, once, on a keypress. Cheaper than keeping every pipeline
    /// resident for visuals that may never be shown.
    func selectScene(_ index: Int) {
        let clamped = ((index % scenes.count) + scenes.count) % scenes.count
        sceneLock.lock()
        let changed = clamped != sceneIndexStorage
        sceneIndexStorage = clamped
        sceneLock.unlock()
        guard changed else { return }
        library = nil
        _ = buildPipeline(for: pixelFormat, force: true)
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
        descriptor.colorAttachments[0].pixelFormat = format

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

    func render(layer: CAMetalLayer, audio: AudioEngine, time: Float) {
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
            // Fullscreen triangle: three shader-generated vertices, no buffer,
            // and no seam down the diagonal a two-triangle quad would have.
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
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
        queue.signalDrawable(drawable)
        drawable.present()

        stats.recordFrame(
            encode: CACurrentMediaTime() - encodeStart,
            size: drawable.texture.width * drawable.texture.height
        )
    }
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

    var enabled = ProcessInfo.processInfo.environment["VELO_STATS"] != nil

    func recordDropped() {
        guard enabled else { return }
        lock.lock(); dropped += 1; lock.unlock()
    }

    /// The display link's OWN expected frame duration. If this reads 8.3 ms
    /// the panel is at 120 Hz and we are missing callbacks; if it reads 12.5 ms
    /// the system is simply calling us at 80 Hz. Those need opposite fixes.
    func recordLinkInterval(_ seconds: Double) {
        guard enabled else { return }
        lock.lock(); linkInterval = seconds; lock.unlock()
    }

    func recordWaits(semaphore: Double, drawable: Double) {
        guard enabled else { return }
        lock.lock(); semWaits.append(semaphore); drawWaits.append(drawable); lock.unlock()
    }

    func recordGPU(_ seconds: Double) {
        guard enabled else { return }
        lock.lock(); gpuTimes.append(seconds); lock.unlock()
    }

    func recordFrame(encode: Double, size: Int) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        if lastFrame > 0 { intervals.append(now - lastFrame) }
        lastFrame = now
        encodes.append(encode)
        pixels = size
        let due = now - lastReport >= 2.0
        if due { lastReport = now }
        let snapshotIntervals = due ? intervals : []
        let snapshotEncodes = due ? encodes : []
        let snapshotGPU = due ? gpuTimes : []
        let snapshotDropped = due ? dropped : 0
        let snapshotPixels = pixels
        let snapshotSem = due ? semWaits : []
        let snapshotDraw = due ? drawWaits : []
        let snapshotLink = linkInterval
        if due {
            intervals.removeAll(); encodes.removeAll(); gpuTimes.removeAll(); dropped = 0
            semWaits.removeAll(); drawWaits.removeAll()
        }
        lock.unlock()

        guard due, !snapshotIntervals.isEmpty else { return }
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
            worst, snapshotDropped, snapshotPixels))
        fflush(stdout)
        }
    }
}
