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
    var sceneIndex = 0
    /// `VELO_HDR=1` starts in extended range, so the path can be exercised
    /// without driving the UI.
    var hdrEnabled = ProcessInfo.processInfo.environment["VELO_HDR"] != nil
    /// Claim the panel's native resolution while fullscreen. On a scaled
    /// desktop the compositor otherwise downsamples every frame, which measured
    /// as a hard 80 fps cap on a 120 Hz panel with the GPU 87% idle.
    var nativeInFullScreen = true
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
