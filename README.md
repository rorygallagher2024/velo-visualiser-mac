# Velo Visualiser for macOS

A low latency audio visualiser for Apple Silicon Macs, built to feed live
visuals into OBS Studio.

It is the Mac sibling of the Android
[Velo Visualiser](https://github.com/rorygallagher2024/velo-visualiser/) and
shares its design language and its scenes, but not a line of its code. This one
is Swift and Metal 4 throughout.

## Requirements

Apple Silicon and macOS 26 or newer, deliberately. There is no Intel path and no
Metal 3 fallback. The point of this app is to sit on the current graphics stack
rather than carry compatibility code nobody on the project will run.

Built and tested with Xcode 26.6 and Swift 6.3.

## Build and run

```bash
./build.sh
open "build/Velo Visualiser.app"
```

`build.sh` compiles with SwiftPM, assembles the `.app`, builds the icon from the
Velo mark and signs ad hoc. There is no Xcode project on purpose: everything is
text, so the whole app is diffable and buildable from a terminal.

The first launch asks for microphone access. Core Audio input is gated by
privacy consent even when the device is a loopback such as BlackHole, so this is
required. The app is not listening to your microphone unless you pick it.

One consequence of ad hoc signing is worth knowing about. Consent is keyed to the
code signing hash, and an ad hoc hash changes on every build, so a rebuild can
drop the grant. When that happens the input goes silent with no error, because
that is how macOS answers an unauthorised stream. The app now asks explicitly and
writes what it found to its log, so the state is visible rather than guessed at.
See [Diagnostics](#diagnostics).

## Keys

The canvas carries no on screen controls, so nothing of the app's own interface
can end up in the capture. Everything is a key.

| Key | |
|-----|-----|
| `M` | show or hide the controls |
| `F` | fullscreen |
| `H` | HDR on or off |
| `1` to `8` | pick a visual directly |
| `left` `right` | step through the visuals |

## Audio

Pick any Core Audio input in the controls. Two setups this is built around:

* **A loopback device** such as BlackHole. Route the Mac's output through it and
  visualise whatever is playing, without a cable.
* **Your interface.** Take the mixer feed directly, which is usually what a DJ
  rig already sends to the Mac for OBS.

Capture is AUHAL rather than AVAudioEngine, one layer below it, so the device,
the buffer size and the callback can all be set explicitly. The callback writes
into a lock free ring that the render thread reads. Nothing allocates, locks or
blocks on the audio thread.

## Latency

The app asks the device for its smallest supported buffer rather than a fixed
size, so the newest sample in the ring is at most one buffer old. On typical
hardware that is 64 frames, about 1.5 ms.

Presentation runs two frames in flight rather than three. A third drawable buys
smoothness when the GPU occasionally overruns the vsync interval, and charges a
whole frame of delay for it. The GPU here runs between 1 and 6 ms against an
8.3 ms budget at 120 Hz, so there is no overrun to absorb and the third frame
would be pure latency.

Ballistics belong to the scene, not the engine. The engine hands over raw band
values and each scene applies its own attack and release, expressed in seconds
rather than in frames, so the motion is identical at 60 fps and at 240.

The Spectrum Analyser adds the group delay of its 1024 point window, which is the
usual resolution against latency trade and matches the Android app. The Raw
Oscilloscope has none of it and is about as direct as the display allows.

## Visuals

Four instruments, which are honest readouts of the signal, then four generative
scenes, which are driven by band energy rather than measuring it. GPU cost is
measured at 8.1 megapixels.

| Key | Visual | GPU |
|-----|--------|-----|
| `1` | Spectrum Analyser | 1.2 ms |
| `2` | Raw Oscilloscope | 3.4 ms |
| `3` | Circular Spectrum | 1.7 ms |
| `4` | Pocket LED | 2.0 ms |
| `5` | Tunnel | 2.7 ms |
| `6` | Laser Array | 2.4 ms |
| `7` | Spectral Bloom | 5.7 ms |
| `8` | Aurora Drift | 5.9 ms |

**Spectrum Analyser.** Thirty one third octave bands, because that is the
standard a real RTA uses rather than a number picked to fill the screen. Peak
programme ballistics: snap up, glide down. The gravity peak caps are the point,
since they keep the shape of a mix legible for a moment after the transient that
made it has gone.

**Raw Oscilloscope.** A single thin trace straight from the PCM window at flat
linear gain. No glow, no smoothing, no auto gain, so a hot signal genuinely runs
off the top rather than being flattered. One thing changed in the port: Metal has
no line width, so a line strip would draw a half point hairline that aliases into
dots on a Retina drawable. The trace is rasterised in the fragment shader as the
true distance to the nearest waveform segment, which holds a constant pixel width
at any resolution and cannot skip a peak between samples.

**Circular Spectrum.** The same reading bent into a ring: 128 log spaced bins
around the circle, each with a gravity peak dot that falls slower than its bar.
Normalised on the shorter axis, so it stays round in any window shape.

**Pocket LED.** A 24 by 14 dot matrix panel on the hardware meter ladder, green
low through amber to red. Instant attack, smooth release, one peak hold cell per
column, and a standby that settles to a resting glow after a few seconds of
silence and snaps awake on the first signal.

**Tunnel.** An infinite hexagonal corridor. Lows send a ripple travelling away
down the corridor rather than scaling it uniformly, mids slide the wall colour
and highs strobe the ribs. What makes it read as depth rather than as a pattern
is the fog to absolute black at the centre, which is infinitely far away, and a
derivative based line width that lets the wireframe dissolve honestly as it
converges instead of aliasing into speckle.

**Laser Array.** Fourteen beams out of a vanishing point, the way a rig full of
scanners looks through haze. The spin is integrated rather than assigned, so the
array never rewinds when the mix thins out. Two closed forms carry over from the
Android version: the beam angle and palette are constant along a whole ray, and
the twenty step radial accumulation is a geometric series, so it collapses to two
exponentials and a divide.

**Spectral Bloom.** An eight fold kaleidoscope over a domain warped fractal flow.
The petal count is deliberately fixed. Driving it from the mids snapped between
integers and read as a twitch rather than as motion.

**Aurora Drift.** Curtains of fractional Brownian motion over a parallax
starfield. Bass drives their height and surge, mids shift the palette, highs work
the stars.

Adding a visual is one file plus one line in `SceneCatalog`. Everything after the
first two needed nothing else: no renderer change, no protocol change and no new
audio plumbing beyond a 128 bin accessor.

## Into OBS

Today: add a **macOS Screen Capture** source in OBS and pick the Velo window.
There is nothing to configure in the app.

Next: a Syphon server, which is how every VJ app hands frames to OBS. It is a
zero copy IOSurface with alpha, and OBS on macOS ships the client source already.
The render pipeline is arranged so the final frame lands in a texture that can be
published directly, so this is an addition rather than a rewrite.

## Fullscreen

`F` takes a borderless window at exactly the screen frame rather than using
AppKit's native fullscreen, which left the canvas 33 points short of the screen
and cost the fast presentation path.

If the desktop is running a scaled resolution, the app also claims the panel's
native mode for the duration and restores it on exit. Without that, macOS
downsamples every frame and the frame rate drops by a third. Measured: 80 fps
against 120, with the GPU 87 percent idle.

## Frame rate

60, 120, 240 or unlimited, applied in windowed and fullscreen alike. A 60 fps
stream gains nothing from rendering faster. The cap holds the render loop back
before it asks for a drawable, so it genuinely reduces presented frames rather
than sleeping after the work is already done.

## HDR

The toggle switches the layer to extended linear Display P3 with EDR enabled and
the drawable to `rgba16Float`. It is for viewing on the Mac. OBS capturing a
window sees tone mapped standard range, so leave it off when streaming.

## Diagnostics

The app writes to `~/Library/Logs/Velo.log` on every launch, including the input
device, its sample rate, its channel count, the negotiated buffer size and the
microphone consent state.

Standard output only exists when the app is started from a terminal, and a
process launched that way inherits the terminal's privacy grants rather than
using its own, so the one launch that can print is the one launch whose
permissions are not the app's. The file log exists because of that.

Two environment variables help when something looks wrong:

```bash
VELO_STATS=1        # frame timing: fps, waits, encode, true GPU time, drops
VELO_AUDIO_DEBUG=1  # capture and analysis levels, per channel
```

## Layout

```
Sources/Velo/
  VeloApp.swift            SwiftUI app and app model
  ContentView.swift        window and control panel
  MetalCanvasView.swift    CAMetalLayer view, render thread, fullscreen, EDR
  DisplayMode.swift        native resolution switching for fullscreen
  Diagnostics.swift        the log at ~/Library/Logs/Velo.log
  Renderer/
    Renderer.swift         Metal 4 queue, allocators, argument tables, pacing
    Scene.swift            the VeloScene contract and shared shader preamble
    SceneCatalog.swift     the fixed list of visuals
    BandEnergy.swift       shared low, mid and high fold, plus shader helpers
    SpectrumAnalyserScene.swift   RawOscilloscopeScene.swift
    CircularSpectrumScene.swift   PocketLedScene.swift
    TunnelScene.swift             LaserArrayScene.swift
    SpectralBloomScene.swift      AuroraDriftScene.swift
  Audio/
    AudioEngine.swift      device enumeration, AUHAL capture, vDSP analysis
```

Shaders are Metal Shading Language, compiled at runtime from the scene that owns
them. A failure to compile prints rather than presenting a silently black canvas.

## Licence

GPL v3.0. See [LICENSE](LICENSE).

The brand is not covered by that licence. The Velo name, the V chevron and the
app icon are reserved, so a fork should carry its own name and artwork. See
[TRADEMARKS.md](TRADEMARKS.md).
