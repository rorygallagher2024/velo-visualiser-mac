#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Thin, exception-free C bridge to ableton::Link for the Swift layer.
// Mirrors the Android LinkController.h API: enable/disable, poll beats,
// query beat phase / bar phase / tempo / peers.

void velo_link_set_enabled(bool enabled);
bool velo_link_is_enabled(void);

// Beats elapsed since the previous call (0 or 1). Call once per frame
// from the render thread only.
int  velo_link_poll_beats(void);

// Fractional phase within the current beat (0.0 to 1.0).
double velo_link_beat_phase(void);

// Fractional phase within the current bar (0.0 to 1.0), where one bar
// is 4 beats.
double velo_link_bar_phase(void);

// Current shared session tempo in BPM (0 if unavailable).
double velo_link_tempo(void);

// Number of other Ableton Link peers on the network.
int  velo_link_num_peers(void);

#ifdef __cplusplus
}
#endif
