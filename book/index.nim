# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, strformat]
import nimib
import UniMovie

nbInit

nbText: """
# UniMovie

Demultiplexing for video containers. Give it a file and it says what is inside:
tracks, durations, dimensions, rotation, where the keyframes are, and the coded
bytes of any one sample.

Every Nim block below is compiled and run when this page is built, and the
output shown is what the code actually produced. Prose that outlives the API it
describes breaks the build rather than quietly misleading you.

## What a file turns out to be

`readMovieFile` reads structure only — no sample is touched, so the cost is the
size of the header rather than of the file.
"""

let fixture = currentSourcePath.parentDir.parentDir / "tests" / "fixtures" / "av.mp4"

nbCode:
  let movie = readMovieFile(fixture)
  echo "format: ", movie.format
  echo "duration: ", movie.durationSeconds, " s"
  echo "tracks: ", movie.tracks.len
  for index, track in movie.tracks:
    echo "  [", index, "] ", track.kind, " ", track.codec,
      " ", track.width, "x", track.height,
      ", ", track.sampleCount, " samples"

nbText: """
`videoTrack` and `audioTrack` give the index of the first of each, or -1. A
file with no sound is an ordinary file, not an error, so the absence is a
value rather than an exception.

## Keyframes

A player seeking to a time has to start at a sample that decodes on its own.
The container lists them, and where it does not, every sample is one — which is
what an audio track relies on.
"""

nbCode:
  for index, track in movie.tracks:
    echo track.kind, ": ", track.keyframes.len, " of ", track.sampleCount,
      " samples are keyframes"

nbText: """
## The coded bytes, and no further

This is the boundary. `codedSample` hands over one sample exactly as the file
holds it; nothing here interprets those bytes.
"""

nbCode:
  let data = readFile(fixture)
  let sample = codedSample(data, movie.videoTrack, 0)
  echo "first video sample: ", sample.len, " bytes of ",
    movie.tracks[movie.videoTrack].codec

nbText: """
Turning them into pixels belongs to a backend the application registers — on
macOS VideoToolbox, on Windows Media Foundation, elsewhere an `ffmpeg` the user
installed. That is what keeps a patented decoder out of this library and out of
everything that consumes it.

## Rotation counts clockwise

A phone records sideways and writes a transformation matrix rather than turning
the pixels. `ffprobe` reports that matrix counting anticlockwise; this library
counts clockwise, so a file `ffprobe` calls `rotation=90` reads here as 270.
Both describe the same matrix, and the sign is the trap when migrating.
"""

nbCode:
  let rotated = readMovieFile(currentSourcePath.parentDir.parentDir / "tests" /
    "fixtures" / "rotated.mov")
  let track = rotated.tracks[rotated.videoTrack]
  echo "stored ", track.width, "x", track.height,
    ", display rotation ", ord(track.rotation), " degrees clockwise"

nbSave
