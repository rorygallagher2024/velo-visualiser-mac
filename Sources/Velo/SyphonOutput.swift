import Metal
import CSyphon

/// Manages a Syphon Metal server that shares the rendered frame with OBS
/// (or any Syphon client) via zero-copy IOSurface.
///
/// The app renders with Metal 4 (`MTL4CommandQueue`), but Syphon's
/// `publishFrameTexture:onCommandBuffer:` expects a standard
/// `id<MTLCommandBuffer>`. A lightweight standard queue handles the blit.
///
/// To eliminate tearing, the renderer draws into a persistent offscreen
/// texture (not the drawable). The offscreen texture is not
/// `framebufferOnly` and is not recycled, so Syphon can safely read it.
/// An `MTLEvent` serialises the two queues: the Metal 4 render signals
/// after the scene render completes, and the Syphon blit waits before
/// reading the offscreen texture.
final class SyphonOutput: @unchecked Sendable {

    private let device: MTLDevice
    private let blitQueue: MTLCommandQueue
    private var server: SyphonMetalServer?
    private let lock = NSLock()

    private let event: MTLEvent
    private var eventValue: UInt64 = 0

    /// The offscreen texture Syphon reads from. Allocated lazily at the
    /// first publish, and reallocated if the size changes.
    private(set) var offscreen: MTLTexture?
    private var offscreenWidth: Int = 0
    private var offscreenHeight: Int = 0

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let event = device.makeEvent()
        else { return nil }
        self.device = device
        self.blitQueue = queue
        self.event = event
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

    /// Ensure the offscreen texture exists at the requested size.
    /// Returns the texture, or nil on allocation failure.
    func ensureOffscreen(width: Int, height: Int) -> MTLTexture? {
        if let tex = offscreen, offscreenWidth == width, offscreenHeight == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = "Syphon Offscreen"
        offscreen = tex
        offscreenWidth = width
        offscreenHeight = height
        return tex
    }

    /// Signal the event from the Metal 4 queue after the render pass.
    /// Call from the render thread before `queue.commit`.
    var currentEvent: MTLEvent { event }
    var nextEventValue: UInt64 {
        eventValue &+= 1
        return eventValue
    }

    /// Publish the offscreen texture to Syphon clients.
    /// Call from the render thread AFTER `queue.commit`.
    func publish(texture: MTLTexture, afterEvent eventVal: UInt64) {
        lock.lock()
        guard let server else { lock.unlock(); return }
        guard server.hasClients else { lock.unlock(); return }
        lock.unlock()

        guard let cb = blitQueue.makeCommandBuffer() else { return }
        cb.encodeWaitForEvent(event, value: eventVal)

        let region = NSRect(
            x: 0, y: 0,
            width: CGFloat(texture.width),
            height: CGFloat(texture.height)
        )
        server.publishFrameTexture(
            texture,
            on: cb,
            imageRegion: region,
            flipped: true
        )
        cb.commit()
    }
}
