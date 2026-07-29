# Implementation notes

Working notes, not documentation. The reasoning behind the parts that look odd,
the measurements behind the numbers in the README, and the traps that already
cost a day so they do not cost another one.

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
    SceneCatalog.swift     the fixed list of visuals, and the buffer size
    BandEnergy.swift       shared low, mid, high fold, plus shader helpers
    ColumnBallistics.swift shared bar levels and gravity peak holds
    <one file per visual>
  Audio/
    AudioEngine.swift      device enumeration, AUHAL capture, vDSP analysis
```

Adding a visual is one file plus one line in `SceneCatalog`. Ten of the twelve
needed nothing else.

## Measured cost

Per scene, at 8.1 megapixels, 120 Hz cap, on an M4 Pro MacBook Pro. The budget is
8.3 ms.

**Treat this as a ranking, not as constants.** The same scene measured 4.3 ms on
a warm machine with other work running and 1.0 ms on a cold one. What holds
across runs is the order and the rough grouping.

| Visual | GPU (cold) |
|--------|-----|
| Spectrum Bars | 0.2 ms |
| Circular Spectrum | 0.3 ms |
| Spectrogram | 0.2 ms |
| Pocket LED | 0.4 ms |
| Laser Array | 0.4 ms |
| Tunnel | 0.5 ms |
| Phosphor Scope | 1.0 ms |
| Spectrum Analyser | 1.4 ms |
| Raw Oscilloscope | 1.5 ms |
| 3D LED | 1.6 ms |
| Spectral Bloom | 3.6 ms |
| Aurora Drift | 4.8 ms |
| Quicksilver | 5.4 ms |

The heavy three are comfortable at 8.1 Mpx and will not be at 5K fullscreen,
which is 14.7 Mpx, roughly 1.8x the pixels. A render scale control is the fix
when that day comes; `requestDrawableSize` already exists for it.

## Scene owned history

Spectrogram is the only scene that keeps its own GPU resource, and the first
attempt was a texture written with `replace(region:)`, one column per frame,
mirroring what Android does with `glTexSubImage2D`.

**That measured 0.8 fps with the GPU at 2.11 ms.** Writing a texture the GPU may
be reading serialises the queue, and the cost is not visible anywhere in the GPU
timings because the stall is on the CPU.

The fix is a persistent `MTLBuffer` in shared storage, which the scene writes
into directly. There is no upload and no API call at all: the CPU writes 128
floats into the same memory the GPU reads. 119 fps, same hazard profile (one
column of one frame may be half updated, out of 640), and the frequency axis
interpolation moves from the sampler into four lines of shader. `historyBuffer`
on the scene protocol, bound at buffer index 2.

## Frame pacing

There are two independent throttles: a free drawable, and a free slot of
per-frame buffers. They must be the same count and acquired in that order. Get
either wrong and the symptom is a frame rate that is fine in a window and
collapses in fullscreen, because it scales with GPU frame time.

`nextDrawable()` blocks by design, and that block IS the vsync throttle. Doing it
inside a display link callback blocks the main runloop, which starves the timer
driving the callbacks. Measured at 12.3 ms of block against an 8.33 ms display
interval, so callbacks were missed and the rate fell to two thirds. Rendering
now runs on its own thread, where the same block simply paces to the display.

Two frames in flight, not three. A third absorbs an occasional GPU overrun and
costs a full frame of latency, every frame, forever. Nothing here overruns.

The frame cap holds the loop back BEFORE asking for a drawable. Capping after
the fact still burns a vsync wait per frame and does not reduce presented
frames.

## Fullscreen

Borderless window at exactly the screen frame, not AppKit's native fullscreen.
Native left the canvas 33 points short of the screen and cost the fast
presentation path. Measured `window 1512x949 @187` on a `1512x982` screen.

Changing the display mode has to happen in `willEnterFullScreen`. Doing it after
`didEnterFullScreen` resizes the screen underneath a layout that has already
finished, and the canvas ends up off centre.

`drawableSize` set from the main thread does not reliably take while the render
thread holds drawables. It is applied on the render thread, between presents,
via `requestDrawableSize`.

`.autoHideMenuBar` causes resize churn. Use `.hideMenuBar`.

### The scaled resolution trap

On a scaled desktop the compositor downsamples every frame and the frame rate
drops by a third: measured 80 fps against 120, with the GPU 87 percent idle. The
app claims the panel's native mode for the duration of fullscreen and restores
it on exit. `DisplayMode.swift`, using `CGDisplaySetDisplayMode` and the native
timing flag `ioFlags & 0x02000000`.

This took four wrong theories to find, three of which blamed the environment.
The instrumentation gap was the actual problem: timing started AFTER the
drawable was acquired, which hid the stall completely. `waitSem` and
`waitDrawable` exist now for that reason, and `waitDrawable` read 12.32 ms
fullscreen against 2.37 ms windowed the moment they were added.

## HDR

Use `extendedDisplayP3`. Not `extendedLinearDisplayP3`. The names are one word
apart and mean opposite things about what a shader's output is.

Every scene emits display referred colour, the same values that look right
written into an SDR framebuffer. Extended Display P3 shares its transfer function
and primaries with plain Display P3, so 0 to 1 is pixel identical to SDR and only
values above 1.0 reach headroom. The linear variant instead declares those same
values to be linear light: 0.5 displays at about 0.73, every midtone lifts, and
the image washes out while the highlights disappear into the general brightening.
That was shipped and reported as "HDR is pointless", correctly.

Headroom is dynamic. macOS grants none until something sets
`wantsExtendedDynamicRangeContent`, so a query while idle is meaningless. The
same panel measured:

```
idle:                    now 1.00x, potential 16.00x
with EDR requested:      now 6.51x, potential 16.00x
```

Apple's built in panels also trade headroom against SDR brightness, so at full
brightness there may be none at all. The controls report this, and only when
there is a problem.

## Audio

AUHAL rather than AVAudioEngine: one layer lower, so the device, the buffer size
and the callback are all set explicitly. AUHAL is an *output* unit with input
enabled on bus 1 and output disabled on bus 0, which is standard and
unintuitive.

The callback allocates nothing. Two things had to be fixed for that: the capture
scratch buffers were being malloc'd per invocation on the real time thread, and
the FFT split-complex buffers were being allocated per frame on the render
thread at up to 240 allocations a second.

`kAudioUnitProperty_MaximumFramesPerSlice` is set explicitly to bound the
callback against the fixed scratch. Before that, a slice larger than the scratch
was silently dropped on the floor, which is an entire dead input that looks
exactly like silence.

Core Audio string properties come back +1 retained. Use `Unmanaged<CFString>`
and `takeRetainedValue`; pointing at a managed `CFString` variable hands ARC a
value it never owned.

### The privacy consent trap

This cost a long detour and will recur.

Capture is gated by privacy consent, and a denial is delivered as an endless
stream of silence rather than as an error. That is indistinguishable from a
quiet room. The app now requests access explicitly and logs the status.

Worse, consent is keyed to the code signing hash, and `build.sh` signs ad hoc, so
the hash changes on every build and a rebuild can drop the grant. There is no
signing identity on this machine, so this is unfixed. A self signed certificate
would fix it permanently.

Worst of all: a process launched from a terminal inherits the terminal's grants
rather than using its own. So the one launch that can print to stdout is the one
launch whose permissions are not the app's. Measured, same binary, back to back:

```
launched by the system  -> authorization: not determined (never asked), capture opened at 2.014 s
launched from terminal  -> authorization: authorized,                   capture opened at 0.126 s
```

That is why `~/Library/Logs/Velo.log` exists. Diagnose from the file, never from
stdout.

## Scenes

The contract is deliberately narrow: a name, a shader, an update, and a write
into one shared buffer. It is a fragment shader over a fullscreen triangle, with
no vertex buffer and no seam down a diagonal.

Shaders compile at runtime, so a syntax error would otherwise present as a
silently black canvas. Failures print loudly.

`SceneCatalog.sceneBufferBytes` sizes the shared buffer once, with headroom. It
used to be derived from one scene's point count, and the next scene added was
1025 floats against a 1024 float buffer.

GLSL to MSL, the things that actually bite:

* `mod` and `fmod` disagree on negative operands. Every polar scene feeds them
  an angle that goes negative, and the kaleidoscope seam lands in the wrong
  place. `BandEnergy.glslMod` has the GLSL one.
* `atan(y, x)` becomes `atan2(y, x)`.
* Metal has no line width. A `lineStrip` is always one pixel, which is half a
  point on a Retina drawable and aliases into dots. Traces are rasterised as
  distance fields instead.
* Framebuffer origin is top left, so every instrument needs the flip in the
  preamble or it stands on its head.

## Removed

**Stereo Scope.** Needs true L/R, which meant making the ring interleaved
stereo. That was reverted along with the scene. Anything in the scope family
needs that ring change first, and it should be its own piece of work.

**Electric Iris.** Ported, ran at 9.9 ms so it was locked to 60 fps, and looked
wrong. Removed rather than guessed at. If it is revisited: the march runs z from
-2.5 to +0.5 while the iris slab only occupies `|z| < 0.5`, so testing the masks
before the FBM rather than after skips most of the work for most pixels, at
identical output.

## Environment hooks

```bash
VELO_STATS=1        # frame timing: fps, waits, encode, true GPU time, drops
VELO_AUDIO_DEBUG=1  # capture and analysis levels, per channel
VELO_HDR=1          # start in extended range
VELO_SCENE=n        # start on a given visual, zero indexed
VELO_CAP=n          # start at a given frame cap
VELO_FULLSCREEN=1   # start fullscreen
VELO_SCALE=n        # drawable scale
```

## Not done

* **Meridian, Waveform, Waveform 3D.** All pure fragment passes, so all
  portable, but each is 300 to 900 lines. Waveform needs `BandWaveHistory` too,
  which is another 430 lines of crossovers and AGC, and it is a `StereoScene`,
  so it wants the stereo ring that was reverted. Its mono path would work today.
* **The two meters.** Level Meter and Mechanical Meter need calibration
  decisions about what full scale means on this input path. Android got that
  wrong twice before it was right, so do it deliberately.
* **Syphon.** How every VJ app hands frames to OBS: a zero copy IOSurface with
  alpha, and OBS ships the client source already. The pipeline is arranged so
  the final frame lands in a texture that can be published directly.
* **Render scale control.** Needed before the heavy scenes run at 5K.
* **Scene categories.** Twelve visuals and ten digit keys. Android solved this
  with Instruments / Reactive / Immersive filters.
