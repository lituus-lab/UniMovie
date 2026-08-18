# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniMovie — umbrella module. Re-exports every public submodule.
##
## Demultiplexing for video containers: tracks, timescales, durations,
## dimensions, rotation, keyframe indices, and the coded bytes of any one
## sample. It answers what `ffprobe` answers, in process.
##
## It holds no decoder. A track reports the code its samples are in, and turning
## those bytes into pixels belongs to a backend the application registers — so
## neither this library nor anything consuming it carries a patented decoder.
import UniMovie/types
import UniMovie/isobmff
import UniMovie/matroska
import UniMovie/avi
import UniMovie/mpegts
import UniMovie/ogg
import UniMovie/mux
import UniMovie/probe
# `probe` is the one that dispatches on the file's own bytes, so its
# `readMovie`, `codedSample` and `codedSampleCount` are the ones this umbrella
# offers; the per-container versions stay reachable by importing that module
# directly. Exporting both would make every call ambiguous.
export types, probe, mux
export isobmff except readMovie, readMovieFile, codedSample, codedSampleCount
export matroska except codedSample, codedSampleCount
export avi except codedSample, codedSampleCount
export mpegts except codedSample, codedSampleCount
export ogg except codedSample, codedSampleCount

const UniMovieVersion* = "0.1.0"


