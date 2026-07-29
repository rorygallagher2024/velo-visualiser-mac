import SwiftUI

/// The window. The canvas is the whole surface — no persistent chrome, matching
/// the Android app's "pure output" rule. Controls slide in only when asked for,
/// and every one of them has a key.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MetalCanvasView(
                hdrEnabled: model.hdrEnabled,
                audio: model.audio,
                onToggleMenu: { model.menuOpen.toggle() },
                onToggleHDR: { model.hdrEnabled.toggle() },
                nativeInFullScreen: model.nativeInFullScreen,
                frameCap: model.frameCap,
                sceneIndex: model.sceneIndex,
                onSceneChange: { model.sceneIndex = $0 }
            )
            .ignoresSafeArea()

            if model.menuOpen {
                ControlPanel(model: model)
                    .padding(20)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HintBar()
                    .padding(14)
            }
        }
        .background(.black)
        .animation(.easeOut(duration: 0.18), value: model.menuOpen)
    }
}

/// A quiet, transient reminder of the keys. There is no on-screen button to
/// open the menu on purpose: a visible control would show up in the OBS capture.
private struct HintBar: View {
    @State private var visible = true

    var body: some View {
        Text("M controls · F fullscreen · H HDR · 1-9 0 / ← → visual")
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(.white.opacity(0.35))
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 1.2)) { visible = false }
            }
    }
}

/// Settings, modelled on the Android sheet: dark panel, small caps section
/// headers, captions beneath their control.
///
/// The HDR caption reports live display headroom, because a toggle that does
/// nothing is indistinguishable from a toggle that is broken.
private struct ControlPanel: View {
    @Bindable var model: AppModel
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Visual")
            VStack(alignment: .leading, spacing: 6) {
                Picker("Visual", selection: $model.sceneIndex) {
                    ForEach(Array(SceneCatalog.names.enumerated()), id: \.offset) { i, n in
                        Text(n).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                caption("Number keys pick a visual directly; left and right "
                        + "arrows step through them.")
            }

            Divider().overlay(.white.opacity(0.12))

            section("Audio")
            VStack(alignment: .leading, spacing: 6) {
                Picker("Input", selection: $model.selectedDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                caption("Any Core Audio input. Use your interface to take a "
                        + "mixer feed directly, or a loopback device to "
                        + "visualise what the Mac itself is playing.")
            }

            Divider().overlay(.white.opacity(0.12))

            section("Display")
            VStack(alignment: .leading, spacing: 6) {
                Toggle("HDR", isOn: $model.hdrEnabled)
                    .toggleStyle(.switch)
                caption("Brighter highlights, on displays that can show them.")
                // Headroom is the whole story for whether this toggle can do
                // anything, and it is not a fixed property of the Mac: Apple's
                // built-in panels trade it against SDR brightness, so at full
                // brightness there is often none. Without saying so, the switch
                // looks broken when it is the display that has no room.
                if let warning = Self.headroomWarning(hdrOn: model.hdrEnabled) {
                    caption(warning)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Frame rate", selection: $model.frameCap) {
                    Text("60 fps").tag(60.0)
                    Text("120 fps").tag(120.0)
                    Text("240 fps").tag(240.0)
                    Text("Unlimited").tag(0.0)
                }
                .labelsHidden()
                .frame(width: 260)
                caption("Applies in windowed and fullscreen alike. A 60 fps "
                        + "stream gains nothing from rendering faster, and the "
                        + "headroom keeps the machine cool and quiet.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Native resolution in fullscreen", isOn: $model.nativeInFullScreen)
                    .toggleStyle(.switch)
                caption("Off by default. Switching the display mode costs more frame rate "
                        + "than the scaled desktop does, so only turn it on if it measures better.")
            }

            Spacer(minLength: 0)
            Text("M close · F fullscreen · H HDR · ← → visual")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(20)
        .frame(width: 320)
        .background(.black.opacity(0.82), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .task {
            devices = AudioEngine.inputDevices()
        }
        .onChange(of: model.selectedDeviceUID) { _, uid in
            model.audio.start(deviceUID: uid)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.45))
    }

    /// Said only when something is wrong.
    ///
    /// A number nobody asked for is noise, but silently doing nothing is worse:
    /// macOS grants no headroom until something requests extended range, so a
    /// display can be perfectly capable and still show no effect until the
    /// brightness comes down.
    static func headroomWarning(hdrOn: Bool) -> String? {
        guard let screen = NSScreen.main else { return nil }
        guard screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01 else {
            return "This display cannot show extended range."
        }
        guard hdrOn,
              screen.maximumExtendedDynamicRangeColorComponentValue <= 1.01
        else { return nil }
        return "No headroom at this brightness. Turn the display down to see it."
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}
