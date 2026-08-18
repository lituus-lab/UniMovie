# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniMovie — umbrella module. Re-exports every public submodule.
##
## Demultiplexing for video containers: tracks, timescales, durations,
## dimensions, rotation, keyframe indices, and the coded bytes of any one
## sample. It replaces a call to `ffprobe`.
##
## It holds no decoder. A track reports the code its samples are in, and turning
## those bytes into pixels belongs to a backend the application registers — so
## neither this library nor anything consuming it carries a patented decoder.
import UniMovie/types
import UniMovie/isobmff
export types, isobmff

const UniMovieVersion* = "0.1.0"


