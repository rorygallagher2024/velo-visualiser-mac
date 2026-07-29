import SwiftUI

@main
struct VeloApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Velo Visualiser", id: "canvas") {
            ContentView(model: model)
                .background(.black)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 720)
        // No `.keyboardShortcut` commands here on purpose. A menu key equivalent
        // is matched before the responder chain, so declaring M/H/F up here
        // would shadow the canvas view that actually handles them.
    }
}

/// App-wide state. `@Observable` rather than `ObservableObject`: SwiftUI only
/// re-renders the views that actually read a changed property, which matters
/// when a 120 Hz canvas shares a window with the controls.
@Observable
final class AppModel {
    var menuOpen = false
    /// Diagnostics overlay. Off by default: the canvas is meant to be pure
    /// output, and anything drawn over it lands in whatever captures the window.
    var perfOverlay = ProcessInfo.processInfo.environment["VELO_PERF"] != nil
    /// Polled from the render thread's stats at 4 Hz.
    var perf = PerfSnapshot()
    var audioStatus = AudioStatus()
    /// Filled once the canvas exists. See `StatsBox` for why this is not state.
    let statsBox = StatsBox()
    var sceneIndex = 0
    /// `VELO_HDR=1` starts in extended range, so the path can be exercised
    /// without driving the UI.
    var hdrEnabled = ProcessInfo.processInfo.environment["VELO_HDR"] != nil
    /// Claim the panel's native resolution while fullscreen.
    ///
    /// OFF by default, which reverses an earlier decision. Claiming the mode
    /// was added to recover frame rate on a scaled desktop, and measured
    /// against itself it now does the opposite: switching the mode leaves the
    /// compositor doing periodic work that stalls the render thread for about
    /// 270 ms once or twice a second.
    ///
    ///     with the claim:     88-103 fps, 1-2 stalls per 2 s, 5.9 Mpx
    ///     without the claim:  118-119 fps, no stalls,         8.4 Mpx
    ///
    /// Slower while drawing 40 percent MORE pixels, which is as clear as a
    /// result gets. Left as a toggle because a different panel may behave
    /// differently, but nothing should opt into it without measuring first.
    var nativeInFullScreen = ProcessInfo.processInfo.environment["VELO_NATIVE"] != nil
    /// 0 means uncapped (present every vsync).
    var frameCap: Double = {
        if let c = ProcessInfo.processInfo.environment["VELO_CAP"], let v = Double(c) {
            return v
        }
        return 0
    }()
    var selectedDeviceUID: String?
    let audio = AudioEngine()

    init() {
        if ProcessInfo.processInfo.environment["VELO_SELFTEST"] != nil { SelfTest.run() }
        VeloLog.begin()
        audio.start()
    }
}
