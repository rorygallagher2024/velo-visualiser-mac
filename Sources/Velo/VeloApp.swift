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
    var showingAbout = false
    var showingPrivacy = false
    /// Diagnostics overlay. Off by default: the canvas is meant to be pure
    /// output, and anything drawn over it lands in whatever captures the window.
    var perfOverlay = ProcessInfo.processInfo.environment["VELO_PERF"] != nil
    /// Polled from the render thread's stats at 4 Hz.
    var perf = PerfSnapshot()
    var audioStatus = AudioStatus()
    /// Filled once the canvas exists. See `StatsBox` for why this is not state.
    let statsBox = StatsBox()

    /// Held for the life of the app, to tell macOS this process is not idle.
    ///
    /// App Nap and timer coalescing exist to save power on processes that look
    /// like they are doing nothing much, and an app that renders on its own
    /// thread and presents drawables can look exactly like that from outside.
    /// `.latencyCritical` opts out of coalescing, and the user-initiated option
    /// says the work is on behalf of someone watching it happen.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "Live audio visualisation")
    var sceneIndex = 0
    /// `VELO_HDR=1` starts in extended range, so the path can be exercised
    /// without driving the UI. Saved to UserDefaults so the user's choice persists.
    var hdrEnabled: Bool {
        didSet { UserDefaults.standard.set(hdrEnabled, forKey: "velo_hdr") }
    }

    /// 0 means uncapped (present every vsync).
    var frameCap: Double = {
        if let c = ProcessInfo.processInfo.environment["VELO_CAP"], let v = Double(c) {
            return v
        }
        return 0
    }()
    var selectedDeviceUID: String?
    let audio = AudioEngine()
    let hue = HueState()

    init() {
        let envHDR = ProcessInfo.processInfo.environment["VELO_HDR"] != nil
        self.hdrEnabled = envHDR || UserDefaults.standard.bool(forKey: "velo_hdr")

        if ProcessInfo.processInfo.environment["VELO_SELFTEST"] != nil { SelfTest.run() }
        VeloLog.begin()
        audio.start()
    }
}
