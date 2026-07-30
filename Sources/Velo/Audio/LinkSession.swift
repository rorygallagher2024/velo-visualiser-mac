import Foundation
import CLinkBridge

/// Swift wrapper around the C LinkBridge. One global instance manages the
/// Link session lifetime; the render thread polls beats each frame.
///
/// On macOS there is no multicast lock to manage (unlike Android where the
/// Wi-Fi chip filters UDP discovery packets by default).
enum LinkSession {

    /// Join or leave the local-network Link session.
    static func setEnabled(_ enabled: Bool) {
        velo_link_set_enabled(enabled)
    }

    /// Beats elapsed since the previous call (0 or 1). Call once per frame
    /// from the render thread only.
    static func pollBeats() -> Int {
        Int(velo_link_poll_beats())
    }

    /// Fractional phase within the current beat (0.0 to 1.0).
    static func beatPhase() -> Float {
        Float(velo_link_beat_phase())
    }

    /// Fractional phase within the current bar (0.0 to 1.0), where one bar
    /// is 4 beats.
    static func barPhase() -> Float {
        Float(velo_link_bar_phase())
    }

    /// Current shared session tempo in BPM (0 if unavailable).
    static func tempo() -> Float {
        Float(velo_link_tempo())
    }

    /// Number of other Ableton Link peers on the network.
    static func numPeers() -> Int {
        Int(velo_link_num_peers())
    }
}
