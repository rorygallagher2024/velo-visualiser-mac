import CoreGraphics
import IOSurface
import Metal
import CSyphon

/// Manages a Syphon Metal server that shares the rendered frame with OBS
/// (or any Syphon client) via zero-copy IOSurface.
///
/// The app renders with Metal 4 (`MTL4CommandQueue`), but Syphon's
/// `publishFrameTexture:onCommandBuffer:` expects a standard
/// `id<MTLCommandBuffer>`. A lightweight standard queue handles the blit.
///
///
/// To eliminate tearing, the renderer draws into a persistent offscreen
/// texture (not the drawable). The offscreen texture is not
/// `framebufferOnly` and is not recycled, so Syphon can safely read it.
/// The Syphon blit is scheduled from the Metal 4 commit feedback handler,
/// ensuring the render is fully complete before Syphon reads it.
final class SyphonOutput: @unchecked Sendable {

    private let device: MTLDevice
    private let blitQueue: MTLCommandQueue
    private var server: SyphonMetalServer?
    private let lock = NSLock()

    /// The offscreen texture Syphon reads from. Allocated lazily at the
    /// first publish, and reallocated if the size changes.
    private(set) var offscreen: MTLTexture?
    private var offscreenWidth: Int = 0
    private var offscreenHeight: Int = 0
    /// The surface that has already been tagged, so tagging happens once.
    private var taggedSurface: IOSurfaceRef?

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

    /// Publish the offscreen texture to Syphon clients.
    /// Call from the render thread AFTER the render has completed on the GPU
    /// (e.g., from the feedback handler).
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
            flipped: true
        )
        cb.commit()

        tagColourSpace(on: server)
    }

    /// Declare the colour space the shared pixels are actually in.
    ///
    /// Now sRGB, not Display P3, because the shaders convert to Rec.709 while
    /// Syphon is running — sRGB and Rec.709 share primaries, so this is the
    /// right thing to declare. Tagging alone was tried first and did not restore
    /// the lost vibrancy, which suggests the client ignores the attachment; the
    /// tag stays because it is correct and free for any client that does read it.
    private func tagColourSpace(on server: SyphonMetalServer) {
        guard let texture = server.newFrameImage(),
              let surface = texture.iosurface
        else { return }

        // Cheap identity check first: IOSurfaceSetValue serialises into the
        // kernel, which the header explicitly calls expensive, so this must not
        // run per frame.
        if let tagged = taggedSurface, CFEqual(tagged, surface) { return }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let plist = space.copyPropertyList()
        else { return }

        IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist)
        taggedSurface = surface
        VeloLog.write("syphon", "tagged shared surface as sRGB / Rec.709")
    }
}
