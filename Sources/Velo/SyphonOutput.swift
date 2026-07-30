import Metal
import CSyphon

/// Manages a Syphon Metal server that shares the rendered frame with OBS
/// (or any Syphon client) via zero-copy IOSurface.
///
/// The app renders with Metal 4 (`MTL4CommandQueue`), but Syphon's
/// `publishFrameTexture:onCommandBuffer:` expects a standard
/// `id<MTLCommandBuffer>`. A lightweight standard queue handles the blit;
/// the GPU serialises the two automatically.
final class SyphonOutput: @unchecked Sendable {

    private let device: MTLDevice
    private let blitQueue: MTLCommandQueue
    private var server: SyphonMetalServer?
    private let lock = NSLock()

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.blitQueue = queue
        blitQueue.label = "com.lowlatency.velo.syphon"
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return server != nil
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard server == nil else { return }
        server = SyphonMetalServer(
            name: "Velo Visualiser",
            device: device,
            options: nil
        )
    }

    func stop() {
        lock.lock()
        let s = server
        server = nil
        lock.unlock()
        s?.stop()
    }

    /// Publish the drawable's texture after the Metal 4 render has committed.
    /// Call from the render thread, AFTER `queue.commit` and BEFORE `present`.
    func publish(texture: MTLTexture) {
        lock.lock()
        guard let server else { lock.unlock(); return }
        guard server.hasClients else { lock.unlock(); return }
        lock.unlock()

        guard let cb = blitQueue.makeCommandBuffer() else { return }
        let region = NSRect(
            x: 0, y: 0,
            width: CGFloat(texture.width),
            height: CGFloat(texture.height)
        )
        server.publishFrameTexture(
            texture,
            on: cb,
            imageRegion: region,
            flipped: false
        )
        cb.commit()
    }
}
