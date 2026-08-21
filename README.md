<p align="center">
  <img src="Resources/velo_logo.png" alt="Velo Visualiser" width="420">
</p>

## Velo Visualiser for macOS: Low Latency Music Visuals

Velo Visualiser is a macOS audio visualiser engineered around one primary
objective: **low latency**.

Point it at any audio input and the picture moves with the sound. The app hears,
analyses and draws in **under 10 ms**; the finished frame then rides the normal
display pipeline that no app can skip, reaching your eyes in roughly
**10 to 25 ms** on a 120 Hz display or **6 to 17 ms** at 240 Hz.

It is the Mac sibling of the Android
[Velo Visualiser](https://github.com/rorygallagher2024/velo-visualiser/) and
shares its design language and its visuals. This one
is Swift and Metal 4 throughout, Apple Silicon only, with no compatibility
layers in the way.

## Demo

<p align="center">
  <a href="https://youtu.be/PL_snHzP5fE">
    <img src="https://img.youtube.com/vi/PL_snHzP5fE/maxresdefault.jpg"
         alt="Watch Velo Visualiser in action" width="720">
  </a>
</p>

<p align="center">
  <a href="https://youtu.be/PL_snHzP5fE"><b>Watch the demo on YouTube</b></a>
</p>

## What's the app for

1. **Visualising music on a Mac.** A modern take on the classic desktop
   visualisers, except now capable of being more responsive at high frame rates with HDR highlights,
   on a canvas that fills whatever display you give it.

2. **A live performance tool.** With built-in Syphon support - It is built to be captured.
    The canvas carries no on screen controls at all, so nothing of the app's own interface can
    land in a recording or a stream, and everything is on a key instead.

3. **Playing Oscilloscope Music.** Features dedicated, true stereo "Lissajous Scope"
   and phosphor "CRT Scope" modes designed to perfectly render the mathematical
   audio-visual vector art of oscilloscope music (like Jerobeam Fenderson).
   Local file playback feeds the scopes sample-accurately at the file's native
   rate, up to 192 kHz. *(We highly recommend lossless files like WAV or FLAC,
   as MP3 or YouTube compression will permanently destroy the shape geometries!)*

4. **Watching what your mix is actually doing.** With a real third octave analyser, two
   oscilloscopes, a scrolling spectrogram and a peak reading LED panel, all fed
   from the same low latency capture.

## Core Features

* **44 Audio-Reactive Visuals:** Waveforms, spectra, particle fluids, scrolling
  spectrograms, dot-matrix LED meters, true stereo XY oscilloscopes (including a
  phosphor CRT scope for oscilloscope music), and more.
* **High-FPS, HDR-Capable Visuals:** With real highlights on displays that support
  extended range.
* **Local File Playback:** Open audio files (WAV, FLAC, AIFF, MP3, AAC) with
  Cmd+O or drag and drop. Playback runs at the file's native sample rate (up to
  192 kHz / 32-bit float) and feeds stereo data sample-accurately into the scope
  visuals. Includes seek, loop and full transport controls.
* **True Stereo Oscilloscope Rendering:** Dedicated "Lissajous Scope" and
  phosphor "CRT Scope" visuals for rendering mathematical vector audio art
  (oscilloscope music). The CRT scope features velocity-modulated brightness,
  barrel curvature and a glass-tube vignette, just like a real cathode-ray tube.
  Lossless files give the cleanest traces.
* **Any Core Audio Input:** Route your system output through a loopback device
  and visualise whatever is playing, or take your interface's feed directly.
  Anything macOS lists as an input can drive it.
* **Syphon Output:** Zero-copy GPU sharing into OBS and any Syphon client at a
  fixed 3840×2160, no window capture needed. When Syphon is active the window
  shows a compact control panel instead of the canvas.
* **Favourites:** Mark visuals as favourites in the picker and the first ten
  are keyed to 1–9 and 0 for instant recall during a set.
* **MIDI Control:** Map any MIDI CC or note to step through visuals from a
  hardware controller. MIDI learn makes setup instant.
* **Colour Themes:** Five colour grades (Default, Neon, Warm, Cool and Mono)
  applied to every visual. Cycle with the T key or pick from the controls.
* **Beat Flash Toggle:** Suppress beat-triggered white flashes for chroma-key
  workflows where white goes transparent. Lights and haptics still react.
* **Smart Lighting:** Philips Hue Entertainment streaming, LIFX and Nanoleaf
  sync, with reactivity presets and per-parameter tuning.
* **Beat Sensitivity:** Low, Standard or High. Controls how readily the beat
  detector fires, scaling the threshold and the audio-presence gate.
* **Ableton Link & 4/4 Music Mode:** Wireless tempo sync or automatic
  beat-grid locking for steady electronic music.
* **Diagnostics Overlay:** Frame timing, GPU time, the live visual and the
  audio input, on a key. Off by default, since it draws over the canvas.
* **No Nonsense:** 100% local processing. No data collection. No ads. No cloud
  access at all.

## Controls

The canvas carries no on screen controls, so everything is a key.

| Key | |
|-----|-----|
| `V` | visual picker |
| `M` | show or hide the settings panel |
| `L` | show or hide the lighting panel |
| `T` | cycle colour theme |
| `D` | cycle Crystal Swarm density |
| `S` | Syphon output on or off |
| `B` | beat flash on or off |
| `F` | fullscreen |
| `H` | HDR on or off (hidden when display has no HDR) |
| `P` | diagnostics overlay |
| `Cmd+O` | open audio file for playback |
| `Space` | play/pause file playback |
| `1` to `9`, `0` | jump to a favourite (or catalogue position when no favourites) |
| `left` `right` | step through the visuals |

## MIDI Control

The application listens to every connected MIDI device automatically. You assign controls
via MIDI learn in the settings panel. No config files, no channel hunting.

### Setup

1. Connect your MIDI controller.
2. Open the settings panel (`M`).
3. Scroll to the **MIDI** section.
4. Click **Learn** next to "Next visual" or "Previous visual".
5. Move the knob, fader, or button on your controller that you want to use.
6. The mapping appears immediately and is saved across launches.

### What you can map

| Action | What it does |
|--------|-------------|
| **Previous visual** | Step one visual backward in the catalogue |
| **Next visual** | Step one visual forward in the catalogue |

Both CC messages (knobs, faders, buttons) and note-on messages (pads, keys) are
supported. The mapping stores the MIDI channel and controller/note number, so
you can use any device and any control.

To remove a mapping, click **Clear** next to it.

## Why Velo Visualiser is Fast

### The simple breakdown

Capture runs on Core Audio's AUHAL layer at the smallest buffer the device will
give, straight into a lock free ring that the render thread reads. Nothing
allocates, locks or blocks on the audio thread, and nothing is copied between
the two. The result is that the app hears, analyses and draws in **under 10 ms**.
The finished frame then travels the display pipeline like every app's frames do.

### The detailed breakdown

| Stage | Component | Latency |
|---|---|---|
| **Capture** | Core Audio AUHAL at the device minimum buffer | ~1.5 ms |
| **Ingest** | Lock free ring write | < 0.1 ms |
| **Analysis** | 1024 point FFT into 128 bins, plus scene ballistics | < 0.2 ms |
| **Render** | Metal 4 shader execution | 0.5 to 7 ms |
| **App total** | **Input to finished frame** | **~2 to 9 ms** |
| **Display** | Vsync and compositor at 120 Hz | ~8 to 16 ms |
| **TOTAL (120 Hz)** | **Input to eyes** | **~10 to 25 ms** |
| **Display** | Vsync and compositor at 240 Hz | ~4 to 8 ms |
| **TOTAL (240 Hz)** | **Input to eyes** | **~6 to 17 ms** |

Analysis and render figures are measured rather than estimated. The spread on
render is the difference between the cheapest instrument and the heaviest
raymarched scene, at 8.1 megapixels.

Two decisions do most of the work. The app runs two frames in flight rather than
three, because a third buffers against a GPU overrun that does not happen here
and charges a whole frame of delay to do it. And ballistics live in the scenes,
expressed in seconds rather than in frames, instead of being smoothed once by the
engine and then again by the scene.

## Requirements

Apple Silicon and macOS 26 or newer.

## Installing

Velo is signed ad hoc rather than with a paid Apple Developer certificate, so a
browser download triggers a Gatekeeper warning. Two of the three routes below
avoid it entirely.

The warning is caused by the `com.apple.quarantine` flag, and that flag is set
by **your browser**, not by macOS. Get the app any other way and there is
nothing to clear.

### Download from the terminal — no warning

```bash
curl -L -o velo.zip https://github.com/rorygallagher2024/velo-visualiser-mac/releases/latest/download/velo-visualiser-mac.zip
ditto -x -k velo.zip /Applications
```

Use `ditto`, not `unzip`. The archive is made with `ditto`, and plain `unzip`
does not restore the bundle metadata it stores — the app still launches but its
code signature no longer validates, which is not a state you want an app that
asks for microphone and local-network access to be in.

### Build it yourself — no warning

See [Building from Source](#building-from-source). A locally built app is never
quarantined, so it opens straight away.

### Download in a browser — one warning, once

Either use **System Settings > Privacy & Security**, scroll to the Security
section, and click **Open Anyway** next to the message about Velo Visualiser —
macOS remembers the choice from then on.

Or clear the flag yourself, which needs no admin password:

```bash
xattr -d com.apple.quarantine "/Applications/Velo Visualiser.app"
```

That command deliberately removes a macOS security check, so only run it on
software you trust. Every line of this app is in this repository, and you can
always take the build-it-yourself route instead.

## First launch

The app asks for microphone access on first run. Core Audio input is gated by
privacy consent even when the device is a loopback like BlackHole, so this is
required. Velo is not listening unless you pick an input.

If you use the Hue integration, macOS will also ask for Local Network access.

## Building from Source

```bash
./build.sh
open "build/Velo Visualiser.app"
```

`build.sh` compiles with SwiftPM, assembles the `.app`, builds the icon and signs
ad hoc. There is no Xcode project on purpose: everything is text, so the whole
app is diffable and buildable from a terminal. Built and tested with Xcode 26.6
and Swift 6.3.

The first launch asks for microphone access. Core Audio input is gated by privacy
consent even when the device is a loopback, so this is required. The app is not
listening to your microphone unless you pick it.

Implementation notes, measurements and the reasoning behind the awkward parts are
in [IMPLEMENTATION.md](IMPLEMENTATION.md).

## License

Velo Visualiser is **free and open source software**, licensed under the
**GNU General Public License v3.0**. See [LICENSE](LICENSE).

You're free to use, study, modify, and redistribute it. Any distributed
derivative must also remain GPLv3.

The **Velo Visualiser name, logo, and icons are trademarks and are not covered by
the GPL** (see [TRADEMARKS.md](TRADEMARKS.md)). Forks must rebrand.

No data collection, no ads, no tracking: local only, and it'll stay that way.

## Support

Velo Visualiser is free but its development cost is not, so if it brings some
colour to your music and you'd like to chip in for coffee, it's hugely
appreciated:

<a href="https://www.buymeacoffee.com/rorygallagher2024"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="42"></a>

## About the Developer

Velo Visualiser was engineered by me, Rory Gallagher. I am an Engineer with over
14 years of experience in enterprise software architecture and currently leading
innovation and experimentation teams. My day-to-day focus centers on leading
teams to evaluate and build enterprise capabilities using emerging technologies.

Building Velo Visualiser is a culmination of my interests in music technology and
audio science, live performance, hardware, software engineering and IoT.

Feel free to connect:
* **LinkedIn:** [linkedin.com/in/rory-gallagher-51822532](https://www.linkedin.com/in/rory-gallagher-51822532)
* **YouTube:** [youtube.com/@rorygallagher-redslug](https://www.youtube.com/@rorygallagher-redslug)
* **Medium:** [medium.com/@rorygallagher2010](https://medium.com/@rorygallagher2010)
