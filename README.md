<p align="center">
  <img src="Resources/velo_logo.png" alt="Velo Visualiser" width="420">
</p>

## Velo Visualiser for macOS: Low Latency Music Visuals

Velo Visualiser is a macOS audio visualiser engineered around one primary
objective: **low latency**.

Point it at any audio input and the picture moves with the sound. The app hears,
analyses and draws in **under 10 ms**; the finished frame then rides the normal
display pipeline that no app can skip, reaching your eyes in roughly
**10 to 25 ms** end to end on a 120 Hz display.

It is the Mac sibling of the Android
[Velo Visualiser](https://github.com/rorygallagher2024/velo-visualiser/) and
shares its design language and its visuals. This one
is Swift and Metal 4 throughout, Apple Silicon only, with no compatibility
layers in the way.

## What's the app for

1. **Visualising music on a Mac.** A modern take on the classic desktop
   visualisers, except now at 120 fps with HDR highlights, on a canvas that
   fills whatever display you give it.

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

* **High-FPS, HDR-Capable Visuals:** Targets 120 fps and holds it, with real
  highlights on displays that support extended range.
* **Any Core Audio Input:** Route your system output through a loopback device
  and visualise whatever is playing, or take your interface's feed directly.
  Anything macOS lists as an input can drive it.
* **38 Visuals:**
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

## The visuals

**Instruments**, which are honest readouts of the signal:

* **Level Meter.** A broadcast-style PPM with peak hold, calibrated
  ballistics and a dBFS scale.
* **Mechanical Meter.** A needle meter with realistic inertia and overshoot.
* **Spectrum Analyser.** Thirty one third octave bands with peak programme
  ballistics and gravity peak caps.
* **Raw Oscilloscope.** A single hairline straight from the audio at flat linear
  gain. No smoothing and no auto gain, so a hot signal genuinely runs off the top
  rather than being flattered.
* **Phosphor Scope.** The same trace as a CRT: a bright filament in a coloured
  halo, with edge fringing and beam dwell.
* **Circular Spectrum.** The reading bent into a ring, 128 bars with peak dots.
* **Pocket LED.** A dot matrix panel on the green through amber to red hardware
  ladder, with a standby that wakes on the first signal.
* **Spectrum Bars.** The classic coloured bars with gravity peak caps.
* **3D LED.** The LED panel as an actual object, lenses and chassis, with a
  camera drifting around it.
* **Spectrogram.** A scrolling heatmap of frequency against time. Watch a beat's
  structure scroll away rather than only seeing the present.
* **Waveform.** Nine seconds of rolling min and max history, with bass, mid and
  high painted as separate layers, so a kick and a hat are two different shapes
  rather than one blended colour.
* **Waveform 3D.** The same three envelopes stood up in space as glowing
  curtains running away toward a vanishing point, newest audio beside the
  camera. The music flows toward you.
* **Waveform 3D Void.** The same corridor with the lights off. No air, no floor
  grid, no ambience: just the curtains and their reflection on pure black.

**Generative**, which are driven by the sound rather than measuring it:

* **Beat Pulse.** A warm core that slams open on the beat with expanding
  shockwave rings. Simple and unmissable.
* **Starscape.** A hyperspace star field flying toward you. Bass accelerates
  the warp, beats flash a subset of stars in vivid colour.
* **Tunnel.** An infinite hexagonal corridor with bass ripples travelling away
  down it.
* **Laser Array.** Beams out of a vanishing point, the way a rig full of
  scanners looks through haze.
* **Spectral Bloom.** A kaleidoscope over a fractal flow.
* **Aurora Drift.** Curtains of light over a parallax starfield.
* **Quicksilver.** A mass of liquid metal, raymarched, reflecting a room that is
  also the background.
* **Electric Iris.** A volumetric iris: gaseous nebula around a black pupil that
  dilates with the bass, with SDF lightning arcs on the treble.
* **Nebula.** A volumetric liquid nebula field with audio-reactive FBM turbulence,
  colour shifts, and a twinkling starfield.
* **Phyllotaxis Bloom.** A sunflower spiral where each dot owns one FFT bin,
  centre to rim mapping lows to highs. The bloom breathes with the spectrum.
* **Corner Bloom.** Four spirals radiating from the screen corners, leaving the
  centre clear for camera or content overlays.
* **Beat Fireworks.** Bass transients launch radial bursts of sparks that arc
  under gravity and fade, over a twinkling star field.
* **Chromatic Dots.** Fifteen thousand particles in five colours, one per musical
  element: bass, mid, treble, loudness, beat. Each class appears and disappears
  with its own energy.
* **Chromatic Frame.** The same five particle classes confined to the screen edges,
  leaving the centre clear for DJ camera overlays.
* **Edge Equaliser.** Spectrum bars growing inward from all four screen edges.
  Bass along the bottom, mids up the sides, treble along the top — an analyser
  that doubles as a decorative frame with the centre clear.
* **Edge Waveform.** The live audio waveform traced as a glowing neon line around
  the screen perimeter. Displacement is perpendicular to the edge, so the line
  breathes inward on loud passages while the centre stays open.
* **Crystal Swarm.** A 32,000-particle lattice that breathes and rotates. Bass
  drives waves through the grid, beats bloom the points into bright flashes,
  and the colour palette shifts spatially across the cloud. Density is
  adjustable with the D key or the settings panel.
* **Particle Dust.** A gentle cloud of drifting particles.
* **Ethereal Ribbons.** Flowing ribbons of light, audio-reactive.
* **Abstract Waveform.** A stylised waveform rendering.
* **Spectral Canyon.** A 3D wireframe landscape sculpted from recent spectrum
  history, scrolling toward the horizon. Curated colour ramp from deep indigo
  through cyan to magenta, with peak caps that flare on the beat.
* **Flux.** A volumetric kaleidoscope corridor. The camera drifts through an
  infinite twisted tunnel whose cross-section is mirrored into morphing N-fold
  symmetry, with three layers of coloured glow accumulating along every ray.
* **Fractal Cathedral.** A ray-marched Mandelbox fractal — vast alien
  architecture with real lighting and ambient occlusion. Bass breathes the fold
  scale so the structure morphs, beats pulse the emissive rim, treble adds
  sparkle. Orbit-trap colouring drifts a warm palette through the geometry.
* **Corner Shatter.** Beat-triggered geometric fragments that explode outward
  from each corner and settle back. Bass controls fragment size, treble adds
  sparkle as they scatter. Event-driven — quiet between hits.
* **Audio Web.** A reactive network of drifting points connected by proximity
  lines. Bass speeds the points, mids brighten the connections, highs flare
  the dots.

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
| **TOTAL** | **Input to eyes** | **~10 to 25 ms** |

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
