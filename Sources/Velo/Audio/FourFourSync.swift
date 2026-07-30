import Foundation

/// App-wide flag for "4/4 Music Mode", read on the render thread by the
/// BeatBus and on the diagnostics overlay. A single global holder avoids
/// plumbing it through the view hierarchy.
///
/// When enabled, the beat that drives the visuals, the lights and any future
/// haptics is grid-locked by ``FourFourTracker`` to a steady four-to-the-floor
/// signature instead of firing on every raw bass onset, so stray hits between
/// the beats are ignored. It is an audio-only alternative to Ableton Link for
/// steady electronic music: no network, no DAW, just the sound in the room.
enum FourFourSync {
    nonisolated(unsafe) static var enabled = false

    /// Live tracker status for the diagnostics overlay: the locked tempo in
    /// BPM, or 0 while it is still searching / not confident.
    nonisolated(unsafe) static var statusBpm: Float = 0
}
