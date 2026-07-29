import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Drives rendering on a thread of its own.
///
/// `nextDrawable()` blocks by design — that block IS the vsync throttle. Doing
/// it inside a display-link callback blocks the main runloop, which starves the
/// very timer driving the callbacks: measured at 12.3 ms of block against an
/// 8.33 ms display interval, so callbacks were missed and the rate collapsed to
/// two thirds. On its own thread the same block simply paces us to the display.
///
/// Everything the loop touches is captured once, at construction. Reaching back
/// into the view for the layer or the audio source each frame would be a data
/// race against the main thread, which is exactly what Swift 6 refuses to allow.
private final class RenderLoop: @unchecked Sendable {
    private let renderer: Renderer
    private let layer: CAMetalLayer
    private let audio: AudioEngine
    private let startTime = CACurrentMediaTime()
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private var capHz: Double = 0      // 0 = uncapped (present at vsync)
    private var pendingSize: CGSize?

    /// Drawable size, applied by the render thread.
    ///
    /// Setting `drawableSize` from the main thread while this loop has drawables
    /// outstanding does not reliably take — the canvas stayed at its windowed
    /// size after going fullscreen. Applying it here, between presents, is the
    /// only point at which the layer is genuinely idle.
    func requestDrawableSize(_ size: CGSize) {
        lock.lock()
        if pendingSize != size { pendingSize = size }
        lock.unlock()
    }

    /// Target frame rate, 0 for uncapped. Enforced by holding the loop back
    /// BEFORE asking for a drawable — capping after the fact would still burn a
    /// vsync wait per frame and would not actually reduce presented frames.
    var frameCap: Double {
        get { lock.lock(); defer { lock.unlock() }; return capHz }
        set { lock.lock(); capHz = newValue; lock.unlock() }
    }

    init(renderer: Renderer, layer: CAMetalLayer, audio: AudioEngine) {
        self.renderer = renderer
        self.layer = layer
        self.audio = audio
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        let thread = Thread { [self] in
            var nextDue = CACurrentMediaTime()
            while isRunning {
                let cap = frameCap
                if cap > 0 {
                    let interval = 1.0 / cap
                    let now = CACurrentMediaTime()
                    if now < nextDue { Thread.sleep(forTimeInterval: nextDue - now) }
                    // Re-anchor rather than accumulate, so a late frame does not
                    // leave the loop trying to catch up forever.
                    nextDue = max(nextDue + interval, CACurrentMediaTime())
                }
                lock.lock()
                let resize = pendingSize
                pendingSize = nil
                lock.unlock()
                if let resize, layer.drawableSize != resize {
                    layer.drawableSize = resize
                }
                renderer.render(
                    layer: layer,
                    audio: audio,
                    time: Float(CACurrentMediaTime() - startTime)
                )
            }
        }
        thread.name = "com.lowlatency.velo.render"
        // Above default so a busy UI cannot preempt frame delivery, but not
        // real-time: dropping a frame is survivable, glitching audio is not.
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        thread = nil
    }
}

/// The canvas: a `CAMetalLayer`-backed view.
final class MetalCanvasNSView: NSView {

    private let metalLayer = CAMetalLayer()
    private var renderer: Renderer?
    private var loop: RenderLoop?
    private var observers: [NSObjectProtocol] = []

    /// HDR is a toggle, not a mode: OBS capturing an EDR window generally sees
    /// tone-mapped SDR, so this is for direct viewing.
    var hdrEnabled: Bool = false { didSet { applyColorConfiguration() } }

    /// Whether fullscreen should claim the panel's native resolution.
    var nativeInFullScreen: Bool = true

    /// The live audio source. Scenes pull whatever they need from it — bands
    /// for the analyser, raw samples for the scope — so nothing has to be
    /// marshalled across the thread boundary every frame.
    var audio: AudioEngine?
    var onToggleMenu: (() -> Void)?
    var onToggleHDR: (() -> Void)?

    /// Target frame rate; 0 is uncapped. Streams are usually 60, and there is
    /// no point rendering frames OBS will never sample.
    var frameCap: Double = 0 { didSet { loop?.frameCap = frameCap } }

    /// Selected visual. Driven from the controls; the keys write back through
    /// `onSceneChange` so the picker and the canvas cannot disagree.
    var sceneIndex: Int = 0 {
        didSet { if sceneIndex != oldValue { renderer?.selectScene(sceneIndex) } }
    }
    var onSceneChange: ((Int) -> Void)?

    // Keys are handled here rather than as SwiftUI `.keyboardShortcut`s. Menu
    // key equivalents are matched before the responder chain ever runs, so a
    // menu-declared shortcut would have shadowed this view; and any key with no
    // handler at all reaches NSApplication, which beeps.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": toggleFullScreen()
        case "m": onToggleMenu?()
        case "h": onToggleHDR?()
        default:
            if let n = numberKey(in: event) {
                changeScene(to: n - 1)
                return
            }
            // Arrows step through the catalogue, as the swipe does on Android.
            switch Int(event.keyCode) {
            case 124: changeScene(to: sceneIndex + 1)    // right
            case 123: changeScene(to: sceneIndex - 1)   // left
            default: super.keyDown(with: event)
            }
        }
    }

    /// A digit that names a visual. Derived from the catalogue rather than
    /// listed, so adding a scene doesn't mean remembering to add a key.
    /// `0` is the tenth, by the usual convention, since a single keypress
    /// cannot reach past nine.
    private func numberKey(in event: NSEvent) -> Int? {
        guard let text = event.charactersIgnoringModifiers, let digit = Int(text)
        else { return nil }
        let n = digit == 0 ? 10 : digit
        guard (1...SceneCatalog.names.count).contains(n) else { return nil }
        return n
    }

    private func changeScene(to index: Int) {
        let count = SceneCatalog.names.count
        let wrapped = ((index % count) + count) % count
        sceneIndex = wrapped
        onSceneChange?(wrapped)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        configureLayer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureLayer() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        metalLayer.device = device
        metalLayer.framebufferOnly = true
        // Must equal Renderer.maxFramesInFlight. When these disagree the smaller
        // silently becomes the throttle and nextDrawable() blocks early.
        metalLayer.maximumDrawableCount = Renderer.maxFramesInFlight
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        applyColorConfiguration()
        renderer = Renderer(device: device)
    }

    private func applyColorConfiguration() {
        // Float only when it buys something. rgba16Float is 8 bytes per pixel
        // against bgra8Unorm's 4, and at a fullscreen drawable that is tens of
        // megabytes per frame for range SDR cannot show anyway.
        let format: MTLPixelFormat = hdrEnabled ? .rgba16Float : .bgra8Unorm
        metalLayer.pixelFormat = format
        metalLayer.wantsExtendedDynamicRangeContent = hdrEnabled
        metalLayer.colorspace = CGColorSpace(
            name: hdrEnabled ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3
        )
        renderer?.buildPipeline(for: format)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loop?.stop()
        loop = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        guard window != nil, let renderer, let audio else { return }
        let loop = RenderLoop(renderer: renderer, layer: metalLayer, audio: audio)
        if let want = ProcessInfo.processInfo.environment["VELO_SCENE"], let i = Int(want) {
            renderer.selectScene(i)
        }
        loop.frameCap = frameCap
        loop.start()
        self.loop = loop

        window?.makeFirstResponder(self)
        observeFullScreen()

        if ProcessInfo.processInfo.environment["VELO_FULLSCREEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.toggleFullScreen()
            }
        }
    }

    // MARK: - Fullscreen
    //
    // Deliberately NOT AppKit's native fullscreen. That path animates into its
    // own Space and decides the window frame itself, and it left the canvas
    // 33 pt short of the screen — the menu-bar strip stayed uncovered, which
    // both looks wrong and costs the fast presentation path (measured: 80 fps
    // with a gap, 120 fps covering the screen). Taking a borderless window at
    // exactly the screen frame is what games do, and it is deterministic.

    private var savedFrame: NSRect?
    private var savedStyle: NSWindow.StyleMask?
    var isFullScreen: Bool { savedFrame != nil }

    func toggleFullScreen() {
        isFullScreen ? exitFullScreen() : enterFullScreen()
    }

    private func enterFullScreen() {
        guard let window, let screen = window.screen, savedFrame == nil else { return }
        savedFrame = window.frame
        savedStyle = window.styleMask

        let verbose = ProcessInfo.processInfo.environment["VELO_STATS"] != nil
        if nativeInFullScreen {
            DisplayMode.engageNative(on: screen, verbose: verbose)
        }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.styleMask = [.borderless]
        window.level = .normal

        // The screen's frame only reflects a mode change on the next main-queue
        // turn, so the frame is taken after the hop rather than from the stale
        // value we already have.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self)
        }
    }

    private func exitFullScreen() {
        guard let window, let frame = savedFrame else { return }
        window.styleMask = savedStyle ?? [.titled, .closable, .miniaturizable, .resizable]
        NSApp.presentationOptions = []
        DisplayMode.restore()
        savedFrame = nil
        savedStyle = nil
        DispatchQueue.main.async { [weak self, window] in
            window.setFrame(frame, display: true)
            window.makeFirstResponder(self)
        }
    }

    /// Safety net: put the display and the menu bar back if the app quits while
    /// fullscreen. CoreGraphics also reverts a mode change when the process that
    /// set it exits, so even a crash recovers — but presentation options do not,
    /// hence doing it explicitly.
    private func observeFullScreen() {
        let centre = NotificationCenter.default

        observers.append(centre.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.presentationOptions = []
                DisplayMode.restore()
            }
        })
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    /// Render scale, as the Android app has. Left at 1.0; `VELO_SCALE` overrides
    /// it for testing how much of a frame is fill-bound.
    var renderScale: CGFloat = {
        if let s = ProcessInfo.processInfo.environment["VELO_SCALE"], let v = Double(s) {
            return CGFloat(v)
        }
        return 1.0
    }()

    private func updateDrawableSize() {
        if ProcessInfo.processInfo.environment["VELO_STATS"] != nil, let w = window {
            print("[velo] view \(Int(bounds.width))x\(Int(bounds.height))"
                  + "  window \(Int(w.frame.width))x\(Int(w.frame.height))"
                  + " @\(Int(w.frame.origin.y))"
                  + "  screen \(Int(w.screen?.frame.width ?? 0))x"
                  + "\(Int(w.screen?.frame.height ?? 0))"
                  + "  safeTop \(Int(safeAreaInsets.top)) safeBot \(Int(safeAreaInsets.bottom))")
            fflush(stdout)
        }
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let size = CGSize(
            width: max(bounds.width * scale * renderScale, 1),
            height: max(bounds.height * scale * renderScale, 1)
        )
        if let loop {
            loop.requestDrawableSize(size)
        } else {
            metalLayer.drawableSize = size
        }
    }
}

/// SwiftUI wrapper so the canvas can sit inside the app's normal window chrome.
struct MetalCanvasView: NSViewRepresentable {
    var hdrEnabled: Bool
    var audio: AudioEngine
    var onToggleMenu: () -> Void
    var onToggleHDR: () -> Void
    var nativeInFullScreen: Bool
    var frameCap: Double
    var sceneIndex: Int
    var onSceneChange: (Int) -> Void

    func makeNSView(context: Context) -> MetalCanvasNSView {
        let view = MetalCanvasNSView(frame: .zero)
        view.audio = audio
        view.hdrEnabled = hdrEnabled
        view.onToggleMenu = onToggleMenu
        view.onToggleHDR = onToggleHDR
        view.nativeInFullScreen = nativeInFullScreen
        view.frameCap = frameCap
        view.sceneIndex = sceneIndex
        view.onSceneChange = onSceneChange
        return view
    }

    func updateNSView(_ nsView: MetalCanvasNSView, context: Context) {
        nsView.hdrEnabled = hdrEnabled
        nsView.audio = audio
        nsView.onToggleMenu = onToggleMenu
        nsView.onToggleHDR = onToggleHDR
        nsView.nativeInFullScreen = nativeInFullScreen
        nsView.frameCap = frameCap
        nsView.sceneIndex = sceneIndex
        nsView.onSceneChange = onSceneChange
    }
}
