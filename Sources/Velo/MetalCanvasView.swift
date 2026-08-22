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
    private var _headless = false
    private var _syphonCapped = false

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

    /// When true, renders to the Syphon offscreen texture only — no drawable
    /// is acquired and nothing is presented to the layer. The window can show
    /// a control panel instead.
    var headless: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _headless }
        set { lock.lock(); _headless = newValue; lock.unlock() }
    }

    /// Hold the loop to 60 while Syphon is feeding a client.
    ///
    /// OBS runs at 60, so frames beyond that are re-read or discarded rather
    /// than shown — and pushing a 120 Hz producer at a 60 Hz consumer is what
    /// makes a shared texture look torn. Capping the producer is the cheap fix,
    /// and it takes the place of the global vsync gate that was reinstated to
    /// solve the same complaint at the cost of 40 fps everywhere.
    var syphonCapped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _syphonCapped }
        set { lock.lock(); _syphonCapped = newValue; lock.unlock() }
    }
    private static let syphonHz: Double = 60

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
            var wasHeadless = false
            while isRunning {
                autoreleasepool {
                    let isHeadless = headless
                    // Syphon feeds a 60 Hz consumer, so cap there whether or
                    // not the window is also drawing. Otherwise honour the
                    // user's setting, uncapped included.
                    let cap: Double
                    if isHeadless || syphonCapped {
                        cap = Self.syphonHz
                    } else {
                        cap = frameCap
                    }
                    if cap > 0 {
                        let interval = 1.0 / cap
                        let now = CACurrentMediaTime()
                        if now < nextDue { Thread.sleep(forTimeInterval: nextDue - now) }
                        nextDue = max(nextDue + interval, CACurrentMediaTime())
                    }
                    let t = Float(CACurrentMediaTime() - startTime)
                    if isHeadless {
                        renderer.renderSyphonOnly(audio: audio, time: t)
                    } else {
                        if wasHeadless {
                            renderer.buildPipeline(
                                for: layer.pixelFormat, force: true)
                        }
                        lock.lock()
                        let resize = pendingSize
                        pendingSize = nil
                        lock.unlock()
                        if let resize, layer.drawableSize != resize {
                            layer.drawableSize = resize
                        }
                        renderer.render(layer: layer, audio: audio, time: t)
                    }
                    wasHeadless = isHeadless
                }
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

    /// Not used to drive rendering. Rendering has its own thread, and this only
    /// exists to state a frame rate the app wants and to measure what the
    /// display actually gives.
    ///
    /// A ProMotion display is adaptive: with nothing telling it otherwise,
    /// macOS is free to decide the content is not worth 120 Hz and drop the
    /// panel to a divisor of it. 40 Hz is one of those divisors, and an app
    /// that renders on its own thread and simply presents drawables never says
    /// what it wants, so it gets whatever the system feels like. Declaring a
    /// `preferredFrameRateRange` is how an app asks, and a range whose minimum
    /// equals its maximum is how it asks firmly.
    private var displayLink: CADisplayLink?
    private var lastLinkTime: CFTimeInterval = 0

    /// HDR is a toggle, not a mode: OBS capturing an EDR window generally sees
    /// tone-mapped SDR, so this is for direct viewing.
    var hdrEnabled: Bool = false { didSet { applyColorConfiguration() } }

    var syphonEnabled: Bool = false {
        didSet {
            applySyphonState()
            loop?.headless = syphonEnabled
            applyPresentationPacing()
            // The layer's colour space depends on this now: the shaders emit
            // Rec.709 while Syphon runs, so the tag has to follow.
            applyColorConfiguration()
        }
    }

    /// The live audio source. Scenes pull whatever they need from it — bands
    /// for the analyser, raw samples for the scope — so nothing has to be
    /// marshalled across the thread boundary every frame.
    var audio: AudioEngine?
    var onToggleMenu: (() -> Void)?
    var onToggleLighting: (() -> Void)?
    var onToggleHDR: (() -> Void)?
    var onTogglePerf: (() -> Void)?
    var onToggleSyphon: (() -> Void)?
    var onToggleBeats: (() -> Void)?
    var onCycleTheme: (() -> Void)?
    var onCycleDensity: (() -> Void)?
    var onToggleVisualPicker: (() -> Void)?

    /// Target frame rate; 0 is uncapped. Streams are usually 60, and there is
    /// no point rendering frames OBS will never sample.
    var frameCap: Double = 0 {
        didSet {
            loop?.frameCap = frameCap
            requestRefreshRate()
        }
    }

    /// Live frame timing, for the diagnostics overlay.
    var stats: FrameStats? { renderer?.stats }


    /// Ask the display for the rate we intend to render at, and keep asking:
    /// the panel's own maximum changes when the window moves between screens,
    /// and the request has to follow the frame cap.
    private func requestRefreshRate() {
        guard let displayLink else { return }
        let panel = Double(window?.screen?.maximumFramesPerSecond ?? 120)
        let wanted = frameCap > 0 ? min(frameCap, panel) : panel
        let hz = Float(max(wanted, 1))
        // Minimum equal to maximum. A range leaves the decision with the
        // system, and the system's decision is the problem being fixed.
        displayLink.preferredFrameRateRange =
            CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastLinkTime > 0 { renderer?.stats.recordLinkInterval(now - lastLinkTime) }
        lastLinkTime = now
    }

    /// Selected visual. Driven from the controls; the keys write back through
    /// `onSceneChange` so the picker and the canvas cannot disagree.
    var sceneIndex: Int = 0 {
        didSet { if sceneIndex != oldValue { renderer?.selectScene(sceneIndex) } }
    }
    var onSceneChange: ((Int) -> Void)?
    var favourites: [Int] = []
    
    /// Fade the output to black without stopping the render.
    var visualsFaded: Bool = false {
        didSet { renderer?.fadeOut = visualsFaded }
    }

    /// Display the canvas should fill, by name.
    ///
    /// Plain storage on purpose: assigning it does not move anything. The move
    /// is an explicit act (`sendToPreferredDisplay`), because `updateNSView`
    /// re-assigns every property on every unrelated model change, and a canvas
    /// that leapt to the projector each time a slider moved would be unusable.
    var preferredDisplayName: String?

    /// Last `sendToDisplayRequest` acted on. Seeded at creation so a remembered
    /// display does not seize the app at launch.
    var lastSendRequest = 0

    var onCycleDisplay: (() -> Void)?

    /// A move asked for while fullscreen, waiting for the Space to close.
    private var pendingMove: NSScreen?

    var transitionsEnabled: Bool = false {
        didSet { renderer?.transitionsEnabled = transitionsEnabled }
    }
    
    var transitionDuration: Double = 10.0 {
        didSet { renderer?.transitionDuration = Float(transitionDuration) }
    }

    // Keys are handled here rather than as SwiftUI `.keyboardShortcut`s. Menu
    // key equivalents are matched before the responder chain ever runs, so a
    // menu-declared shortcut would have shadowed this view; and any key with no
    // handler at all reaches NSApplication, which beeps.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": toggleFullScreen()
        case "m": onToggleMenu?()
        case "l": onToggleLighting?()
        case "h": onToggleHDR?()
        case "p": onTogglePerf?()
        case "s": onToggleSyphon?()
        case "b": onToggleBeats?()
        case "t": onCycleTheme?()
        case "d": onCycleDensity?()
        case "v": onToggleVisualPicker?()
        case "e": onCycleDisplay?()
        default:
            if let n = numberKey(in: event) {
                changeScene(to: n)
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

    /// A digit that selects a visual. When favourites exist, 1–9/0 map to the
    /// first ten favourites. Otherwise they index the catalogue directly.
    private func numberKey(in event: NSEvent) -> Int? {
        guard let text = event.charactersIgnoringModifiers, let digit = Int(text)
        else { return nil }
        let slot = digit == 0 ? 9 : digit - 1

        if !favourites.isEmpty {
            guard slot < favourites.count else { return nil }
            return favourites[slot]
        }

        guard slot < SceneCatalog.names.count else { return nil }
        return slot
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
        // Enabled by default for windowed mode, where it gives precise vsync
        // pacing. Recomputed on every fullscreen and Syphon change — see
        // applyPresentationPacing().
        applyPresentationPacing()
        applyColorConfiguration()
        renderer = Renderer(device: device)
        renderer?.transitionsEnabled = transitionsEnabled
        renderer?.fadeOut = visualsFaded
        renderer?.transitionDuration = Float(transitionDuration)
    }

    private func applyColorConfiguration() {
        // Float only when it buys something. rgba16Float is 8 bytes per pixel
        // against bgra8Unorm's 4, and at a fullscreen drawable that is tens of
        // megabytes per frame for range SDR cannot show anyway.
        let format: MTLPixelFormat = hdrEnabled ? .rgba16Float : .bgra8Unorm
        metalLayer.pixelFormat = format
        metalLayer.wantsExtendedDynamicRangeContent = hdrEnabled

        // EXTENDED, not extended-LINEAR. Both exist and the names are one word
        // apart, but they mean opposite things about what a shader's output is.
        //
        // Every scene here emits display-referred colour, the same values that
        // look correct written into an SDR framebuffer. `extendedDisplayP3`
        // shares its transfer function and primaries with `displayP3` exactly,
        // so everything inside 0...1 is pixel-identical to SDR and only values
        // ABOVE 1.0 reach into headroom, which is the whole point of the
        // toggle: same picture, real highlights.
        //
        // `extendedLinearDisplayP3` would instead declare those same values to
        // be linear light. 0.5 then displays at about 0.73, every midtone lifts
        // and the image washes out while the highlights it was supposed to buy
        // disappear into the general brightening.
        // While Syphon is running the shaders convert to Rec.709 on the way out,
        // because that is what the client feeds. The window blits from that same
        // texture, so it has to be told the values are Rec.709 too — tagged P3
        // they would read over-saturated. The upshot is that streaming shows you
        // what your audience gets, and switching Syphon off restores full P3.
        let space: CFString
        if hdrEnabled {
            space = CGColorSpace.extendedDisplayP3
        } else if syphonEnabled {
            space = CGColorSpace.sRGB
        } else {
            space = CGColorSpace.displayP3
        }
        metalLayer.colorspace = CGColorSpace(name: space)
        renderer?.buildPipeline(for: format)
        if hdrEnabled { reportHeadroom() }
    }

    /// What the display can actually give us above SDR white.
    ///
    /// Worth stating out loud, because on Apple's built-in panels headroom is
    /// traded against SDR brightness: at full brightness it can be 1.0, meaning
    /// there is no room above white and the toggle genuinely cannot do
    /// anything. That is a display state, not a bug, and it is invisible unless
    /// asked about.
    private func applySyphonState() {
        // Syphon reads the drawable texture, which requires framebufferOnly = false.
        metalLayer.framebufferOnly = !syphonEnabled
        if syphonEnabled {
            renderer?.syphon?.start()
        } else {
            renderer?.syphon?.stop()
        }
    }

    private func reportHeadroom() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let now = screen.maximumExtendedDynamicRangeColorComponentValue
        let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        VeloLog.write("hdr", String(
            format: "headroom %.2fx now, %.2fx potential on %@%@",
            now, potential, screen.localizedName,
            now <= 1.01
                ? ". No room above white: lower the display brightness to free some."
                : ""))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loop?.stop()
        loop = nil
        displayLink?.invalidate()
        displayLink = nil
        lastLinkTime = 0
        // Remove observers from the previous window BEFORE registering new ones.
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let window {
            for name in [NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fullScreenDidChange() }
                })
            }
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            displayLink = link
            requestRefreshRate()
            link.add(to: .main, forMode: .common)
        }

        guard window != nil, let renderer, let audio else { return }
        let loop = RenderLoop(renderer: renderer, layer: metalLayer, audio: audio)
        if let want = ProcessInfo.processInfo.environment["VELO_SCENE"], let i = Int(want) {
            renderer.selectScene(i)
        }
        loop.frameCap = frameCap
        loop.headless = syphonEnabled
        loop.syphonCapped = syphonEnabled
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
    // Native macOS fullscreen (a Space), and nothing else. A borderless window
    // covering the screen is not fullscreen — it still has a border and it is
    // still an ordinary composited window.
    //
    // The vsync gate is decided by applyPresentationPacing(), not fixed here.

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    /// Decide the vsync gate and the frame cap together, because the two
    /// requirements pull in opposite directions and were previously conflated.
    ///
    /// **Fullscreen wants no gate.** In a Space the display holds each presented
    /// drawable for three vsync periods, so a vsync-gated Space measures exactly
    /// (N - 1) x 40 fps — 80 at the three drawables `CAMetalLayer` allows, and
    /// there is no fourth. Turning the gate off is the only way past that, and
    /// it is where the full panel rate came from.
    ///
    /// **Syphon wants a gate, and 60.** The tearing that prompted the gate being
    /// switched back on was in the Syphon feed, not on the display, and the fix
    /// for it belongs where it happens: the offscreen texture, the barrier before
    /// the blit reads it, and publishing from the commit feedback handler. What
    /// Syphon additionally needs is to match its consumer, and OBS runs at 60.
    /// Restoring the gate globally to solve that cost 40 fps everywhere.
    private func applyPresentationPacing() {
        let syphon = syphonEnabled
        // Gate off only when nothing is being fed downstream and we own the
        // display outright.
        metalLayer.displaySyncEnabled = syphon || !isFullScreen
        loop?.syphonCapped = syphon
    }

    /// The screen `preferredDisplayName` names, if it is still attached.
    private var preferredScreen: NSScreen? {
        preferredDisplayName.flatMap(DisplayTarget.screen(named:))
    }

    /// Put the window on `screen` before it is asked to fill it.
    ///
    /// `toggleFullScreen` builds the Space on whichever display the window
    /// currently occupies — there is no parameter for it — so relocating the
    /// window first is the whole mechanism. `visibleFrame` rather than `frame`:
    /// entering fullscreen from a window already overlapping the menu bar left
    /// a briefly mis-sized Space.
    private func place(_ window: NSWindow, on screen: NSScreen) {
        window.setFrame(screen.visibleFrame, display: true)
    }

    /// Move the canvas to the chosen display and fill it.
    ///
    /// AppKit will not relocate a window that owns a fullscreen Space, so when
    /// one is already open the move is split either side of leaving it, and
    /// finished in `fullScreenDidChange`.
    func sendToPreferredDisplay() {
        guard let window, let target = preferredScreen else { return }
        guard window.screen != target || !isFullScreen else { return }
        if isFullScreen {
            pendingMove = target
            window.toggleFullScreen(nil)
            return
        }
        place(window, on: target)
        toggleFullScreen()
    }

    func toggleFullScreen() {
        guard let window else { return }
        // Going in, land on the chosen display first. Coming out, leave the
        // window where it is — a move on the way out would be a surprise.
        if !isFullScreen, let target = preferredScreen, window.screen != target {
            place(window, on: target)
        }
        // Activate first. A fullscreen Space belonging to an application the
        // system does not consider active is throttled hard, and the app is
        // frequently not active at the moment the key is pressed.
        NSApp.activate()
        // Remove None before inserting Primary. They are mutually exclusive,
        // and a SwiftUI window can carry None, in which case inserting Primary
        // alongside it leaves fullscreen disallowed and `toggleFullScreen`
        // silently does nothing.
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.toggleFullScreen(nil)
    }

    /// AppKit owns the transition, so post-transition state is applied here
    /// rather than around the frame the app set.
    @objc func fullScreenDidChange() {
        guard let window else { return }
        NSApp.presentationOptions = []
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if isFullScreen { NSApp.activate() }
        window.makeFirstResponder(self)
        applyPresentationPacing()
        requestRefreshRate()
        updateDrawableSize()
        completePendingMove()
    }

    /// Second half of a move that had to leave a fullscreen Space first.
    ///
    /// Dispatched rather than run inline: `toggleFullScreen` called from within
    /// the notification for the transition that just finished is ignored, and
    /// the canvas would sit windowed on the new display.
    private func completePendingMove() {
        guard !isFullScreen, pendingMove != nil else { return }
        pendingMove = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            // Resolved again rather than captured: unplugging the projector
            // during the transition out is exactly when this runs, and the
            // captured `NSScreen` would then carry a stale frame and put the
            // window somewhere nothing can reach it.
            guard let target = self.preferredScreen else { return }
            self.place(window, on: target)
            self.toggleFullScreen()
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
        // Only when it actually changed. Changing `drawableSize` makes
        // CAMetalLayer discard and reallocate its whole drawable pool, which
        // stalls the render thread for a couple of hundred milliseconds. AppKit
        // sends resize notifications far more often than the size really
        // changes, so an unguarded path turns every one of them into a hitch.
        guard size != metalLayer.drawableSize else { return }
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
    var syphonEnabled: Bool
    var audio: AudioEngine
    var onToggleMenu: () -> Void
    var onToggleLighting: () -> Void
    var onToggleHDR: () -> Void
    var onTogglePerf: () -> Void
    var onToggleSyphon: () -> Void
    var onToggleBeats: () -> Void
    var onCycleTheme: () -> Void
    var onCycleDensity: () -> Void
    var onToggleVisualPicker: () -> Void
    /// Handed the live stats once the view exists, so the overlay can poll them
    /// without the SwiftUI layer reaching into the renderer itself.
    var onStats: (FrameStats) -> Void
    var frameCap: Double
    var sceneIndex: Int
    var onSceneChange: (Int) -> Void
    var favourites: [Int]
    var transitionsEnabled: Bool
    var transitionDuration: Double
    var visualsFaded: Bool
    var preferredDisplayName: String?
    /// Monotonic counter, not a flag: the same display can be asked for twice
    /// running (after dragging the window off it, say) and a Bool would make
    /// the second ask indistinguishable from the first.
    var sendToDisplayRequest: Int
    var onCycleDisplay: () -> Void

    func makeNSView(context: Context) -> MetalCanvasNSView {
        let view = MetalCanvasNSView(frame: .zero)
        view.audio = audio
        view.hdrEnabled = hdrEnabled
        view.syphonEnabled = syphonEnabled
        view.onToggleMenu = onToggleMenu
        view.onToggleLighting = onToggleLighting
        view.onToggleHDR = onToggleHDR
        view.onTogglePerf = onTogglePerf
        view.onToggleSyphon = onToggleSyphon
        view.onToggleBeats = onToggleBeats
        view.onCycleTheme = onCycleTheme
        view.onCycleDensity = onCycleDensity
        view.onToggleVisualPicker = onToggleVisualPicker
        if let stats = view.stats { onStats(stats) }
        view.frameCap = frameCap
        view.sceneIndex = sceneIndex
        view.onSceneChange = onSceneChange
        view.favourites = favourites
        view.transitionsEnabled = transitionsEnabled
        view.transitionDuration = transitionDuration
        view.visualsFaded = visualsFaded
        view.preferredDisplayName = preferredDisplayName
        view.onCycleDisplay = onCycleDisplay
        // Adopt the count rather than starting from zero, so a display restored
        // from last session is remembered without being acted on.
        view.lastSendRequest = sendToDisplayRequest
        return view
    }

    func updateNSView(_ nsView: MetalCanvasNSView, context: Context) {
        nsView.hdrEnabled = hdrEnabled
        nsView.syphonEnabled = syphonEnabled
        nsView.audio = audio
        nsView.onToggleMenu = onToggleMenu
        nsView.onToggleLighting = onToggleLighting
        nsView.onToggleHDR = onToggleHDR
        nsView.onTogglePerf = onTogglePerf
        nsView.onToggleSyphon = onToggleSyphon
        nsView.onToggleBeats = onToggleBeats
        nsView.onCycleTheme = onCycleTheme
        nsView.onCycleDensity = onCycleDensity
        nsView.onToggleVisualPicker = onToggleVisualPicker
        nsView.frameCap = frameCap
        nsView.sceneIndex = sceneIndex
        nsView.onSceneChange = onSceneChange
        nsView.favourites = favourites
        nsView.transitionsEnabled = transitionsEnabled
        nsView.transitionDuration = transitionDuration
        nsView.visualsFaded = visualsFaded
        nsView.preferredDisplayName = preferredDisplayName
        nsView.onCycleDisplay = onCycleDisplay

        if sendToDisplayRequest != nsView.lastSendRequest {
            nsView.lastSendRequest = sendToDisplayRequest
            // Out of the update pass before touching the window: entering a
            // fullscreen Space from inside SwiftUI's layout is a re-entrant
            // window change, and AppKit drops some of it.
            DispatchQueue.main.async { nsView.sendToPreferredDisplay() }
        }
    }
}
