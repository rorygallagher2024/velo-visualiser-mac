import Foundation

/// App-wide flags for Ableton Link wireless tempo/beat sync, read on the
/// render thread by ``BeatBus``. Mirrors Android's `LinkSync` object.
///
/// When enabled, the beat that drives visuals and lights comes from Link's
/// network clock instead of audio onset detection. The microphone still
/// drives the visuals themselves; Link only controls *when* the beat lands.
enum LinkSync {
    nonisolated(unsafe) static var enabled = false

    /// When true (and Link is on), the visual beat-punch swells into each beat
    /// before snapping on the hit. Only Link can do this because only the shared
    /// clock knows where the next beat lands.
    nonisolated(unsafe) static var anticipateBeat = true

    /// Manual downbeat alignment (0..3 whole beats). Link shares the beat grid
    /// and tempo but NOT where the musical bar "1" sits.
    nonisolated(unsafe) static var barOffsetBeats: Int = 0

    /// Live status for the perf overlay and UI.
    nonisolated(unsafe) static var statusBpm: Float = 0
    nonisolated(unsafe) static var statusPeers: Int = 0
}
