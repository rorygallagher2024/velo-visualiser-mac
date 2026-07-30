#include "LinkBridge.h"

#include <ableton/Link.hpp>

#include <atomic>
#include <cmath>

namespace {

ableton::Link& link() {
    static ableton::Link instance{120.0};
    return instance;
}

constexpr double kQuantum = 4.0;

std::atomic<bool> gRebaseline{true};
double gLastBeat = 0.0;

} // namespace

extern "C" {

void velo_link_set_enabled(bool enabled) {
    try {
        link().enable(enabled);
        if (enabled) gRebaseline.store(true, std::memory_order_relaxed);
    } catch (...) {}
}

bool velo_link_is_enabled() {
    try {
        return link().isEnabled();
    } catch (...) {
        return false;
    }
}

int velo_link_poll_beats() {
    try {
        auto& l = link();
        if (!l.isEnabled()) {
            gRebaseline.store(true, std::memory_order_relaxed);
            return 0;
        }

        const auto time = l.clock().micros();
        const auto state = l.captureAudioSessionState();
        const double beat = state.beatAtTime(time, kQuantum);

        if (gRebaseline.exchange(false, std::memory_order_relaxed)) {
            gLastBeat = beat;
            return 0;
        }

        const long prev = static_cast<long>(std::floor(gLastBeat));
        const long curr = static_cast<long>(std::floor(beat));
        gLastBeat = beat;

        long delta = curr - prev;
        if (delta < 0) delta = 0;
        if (delta > 4) delta = 1;
        return static_cast<int>(delta);
    } catch (...) {
        return 0;
    }
}

double velo_link_beat_phase() {
    try {
        auto& l = link();
        if (!l.isEnabled()) return 0.0;
        const auto time = l.clock().micros();
        const auto state = l.captureAppSessionState();
        const double beat = state.beatAtTime(time, kQuantum);
        return beat - std::floor(beat);
    } catch (...) {
        return 0.0;
    }
}

double velo_link_bar_phase() {
    try {
        auto& l = link();
        if (!l.isEnabled()) return 0.0;
        const auto time = l.clock().micros();
        const auto state = l.captureAppSessionState();
        const double phase = state.phaseAtTime(time, kQuantum);
        return phase / kQuantum;
    } catch (...) {
        return 0.0;
    }
}

double velo_link_tempo() {
    try {
        return link().captureAppSessionState().tempo();
    } catch (...) {
        return 0.0;
    }
}

int velo_link_num_peers() {
    try {
        return static_cast<int>(link().numPeers());
    } catch (...) {
        return 0;
    }
}

} // extern "C"
