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

## What's the app for

1. **Visualising music on a Mac.** A modern take on the classic desktop
   visualisers, except now capable of being more responsive at high frame rates with HDR highlights,
   on a canvas that fills whatever display you give it.

2. **A live performance tool.** It is built to be captured. The canvas carries
   no on screen controls at all, so nothing of the app's own interface can land
   in a recording or a stream, and everything is on a key instead. Point a
   capture source at the window, or run it fullscreen on a projector or a second
   display.

3. **Watching what your mix is actually doing.** Most of the visuals are
   instruments rather than decoration: a real third octave analyser, two
   oscilloscopes, a scrolling spectrogram and a peak reading LED panel, all fed
   from the same low latency capture.

## Core Features

* **High-FPS, HDR-Capable Visuals:** With real highlights on displays that supports
  extended range.
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
* **Colour Themes:** Five colour grades — Default, Neon, Warm, Cool and Mono —
  applied to every visual. Cycle with the T key or pick from the controls.
* **Beat Flash Toggle:** Suppress beat-triggered white flashes for chroma-key
  workflows where white goes transparent. Lights and haptics still react.
* **Smart Lighting:** Philips Hue Entertainment streaming, LIFX and Nanoleaf
  sync, with reactivity presets and per-parameter tuning.
* **Beat Sensitivity:** Low, Standard or High — controls how readily the beat
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
| `1` to `9`, `0` | jump to a favourite (or catalogue position when no favourites) |
| `left` `right` | step through the visuals |

## MIDI Control

Velo listens to every connected MIDI device automatically. You assign controls
via MIDI learn in the settings panel — no config files, no channel hunting.

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
