/* SPDX-License-Identifier: GPL-3.0-only
 * The interleaved WriteMix ring is adapted from BlackHole.
 * Copyright (C) 2019 Existential Audio Inc.
 */
#pragma once

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

enum { ODSampleRate = 48000, ODChannels = 2, ODMaxFrames = 960, ODBlockCount = 4 };

typedef struct {
    uint64_t hostTime;
    uint32_t frames;
    float samples[ODMaxFrames * ODChannels];
} ODBlock;

typedef struct {
    _Atomic uint64_t written;
    _Atomic uint64_t consumed;
    ODBlock blocks[ODBlockCount];
} ODRing;

static inline void ODRingReset(ODRing *ring) {
    atomic_store_explicit(&ring->written, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->consumed, 0, memory_order_relaxed);
}

// Only WriteMix writes. The reader owns consumed, including when it skips late
// blocks. A full ring drops new audio until the reader catches up.
static inline void ODRingWrite(ODRing *ring, const float *samples, uint32_t frames, uint64_t hostTime) {
    if (frames > ODMaxFrames * ODBlockCount) {
        samples += (frames - ODMaxFrames * ODBlockCount) * ODChannels;
        frames = ODMaxFrames * ODBlockCount;
    }
    while (frames) {
        const uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
        if (written - atomic_load_explicit(&ring->consumed, memory_order_acquire) >= ODBlockCount) return;
        ODBlock *block = &ring->blocks[written % ODBlockCount];
        block->frames = frames > ODMaxFrames ? ODMaxFrames : frames;
        block->hostTime = hostTime;
        memcpy(block->samples, samples, block->frames * ODChannels * sizeof(float));
        frames -= block->frames;
        samples += block->frames * ODChannels;
        atomic_store_explicit(&ring->written, written + 1, memory_order_release);
    }
}

static inline uint32_t ODRingRead(ODRing *ring, float *samples, uint64_t oldestTime) {
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint64_t consumed = atomic_load_explicit(&ring->consumed, memory_order_relaxed);
    uint32_t frames = 0;
    while (consumed < written) {
        const ODBlock *block = &ring->blocks[consumed % ODBlockCount];
        if (block->hostTime >= oldestTime) {
            if (frames + block->frames > ODMaxFrames) break;
            memcpy(samples + frames * ODChannels, block->samples, block->frames * ODChannels * sizeof(float));
            frames += block->frames;
        }
        atomic_store_explicit(&ring->consumed, ++consumed, memory_order_release);
    }
    return frames;
}
