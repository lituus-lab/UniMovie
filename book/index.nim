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
The same call works whatever the container turns out to be, and what comes back
is the form that container stores — an MP4 gives length-prefixed units where a
transport stream gives start codes. What differs sharply is the cost: ISO base
media reads an offset from a table, while the others index nothing and have to
be walked.
"""

nbCode:
  for name in ["tiny.mp4", "tiny.mkv", "tiny.webm", "tiny.avi", "tiny.ts",
               "tiny.ogv"]:
    let bytes = readFile(currentSourcePath.parentDir.parentDir / "tests" /
                         "fixtures" / name)
    let shape = readMovie(bytes)
    let video = shape.videoTrack
    echo name, ": ", codedSampleCount(bytes, video), " samples, first is ",
      codedSample(bytes, video, 0).len, " bytes of ",
      shape.tracks[video].codec

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


nbText: """
## Five containers, one call

`readMovieFile` identifies the container from its bytes and dispatches. The
extension is never consulted — a `.avi` holding a Matroska stream is a real
thing, and a caller should not have to guess.
"""

nbCode:
  let fixtures = currentSourcePath.parentDir.parentDir / "tests" / "fixtures"
  for name in ["tiny.mp4", "tiny.mkv", "tiny.webm", "tiny.avi", "tiny.ts",
               "tiny.ogv"]:
    let each = readMovieFile(fixtures / name)
    let shown = each.tracks[each.videoTrack]
    echo name, ": ", each.format, ", ", shown.codec, " ",
      shown.width, "x", shown.height

nbText: """
The codec is reported as the four-character code MP4 uses, whichever container
it came from: Matroska writes `V_MPEG4/ISO/AVC` where MP4 writes `avc1`, and
both read here as `avc1`. A caller registers one backend per codec rather than
one per container, which is the point.

A transport stream is the exception to "the container says everything": it
carries no dimensions at all, so an H.264 picture size comes from the sequence
parameter set. Reading a parameter set produces no pixel — it is the same thing
`ffprobe` does to answer the same question.
"""

nbText: """
## Writing one back

The other half assembles a container around samples somebody else encoded, and
never produces one. A remux therefore reads the samples out and writes them
straight back in, and the pictures that come out are the pictures that went in.

Two numbers have to travel with each sample. Its duration, and how far its
display time sits from its decode time — the composition offset, which is
non-zero only where the encoder reordered. Dropping the second is the classic
way to produce a file that is perfectly well formed and plays out of order.
"""

nbCode:
  let clip = currentSourcePath.parentDir.parentDir / "tests" / "fixtures" /
             "tiny.mp4"
  let bytes = readFile(clip)
  let shape = readMovie(bytes)
  let index = shape.videoTrack
  let timing = sampleTiming(bytes, index)
  let destination = getTempDir() /
    ("unimovie-book-" & $getCurrentProcessId() & ".mkv")

  var writer = newMatroskaWriter(destination, [TrackParams(
    kind: tkVideo, codec: shape.tracks[index].codec,
    timescale: shape.tracks[index].timescale,
    width: shape.tracks[index].width, height: shape.tracks[index].height,
    edits: editList(bytes, index))])
  for sample in 0 ..< shape.tracks[index].sampleCount:
    var payload: seq[byte]
    for character in codedSample(bytes, index, sample):
      payload.add byte(character)
    writer.writeSample(0, payload, timing[sample].duration,
                       sample in shape.tracks[index].keyframes,
                       timing[sample].compositionOffset)
  writer.close()

  let written = readFile(destination)
  # The count is compared before the samples are: a writer that dropped one
  # would otherwise pass, since a shorter loop still matches every sample it
  # runs over.
  var identical = codedSampleCount(written, 0) ==
    shape.tracks[index].sampleCount
  if identical:
    for sample in 0 ..< codedSampleCount(written, 0):
      if codedSample(written, 0, sample) != codedSample(bytes, index, sample):
        identical = false
  echo "wrote ", readMovie(written).format, ", ",
    codedSampleCount(written, 0), " samples, identical to the source: ",
    identical
  removeFile(destination)

nbText: """
`newMp4Writer` and `newFragmentedMp4Writer` take the same tracks and the same
samples. The fragmented one puts `moov` first with empty tables and writes a
`moof`/`mdat` pair per fragment, so it never seeks backwards and a player can
start on the first pair — which is what a live stream needs and what a
whole-file writer cannot give it.

Where a fragment or a cluster breaks is the caller's decision, not this
library's: one that does not start on a keyframe cannot be played on its own,
and that is most of the reason to write one.

An edit list is the third thing that has to travel. It says a track plays
something other than its media from the start — cancelling the offset a
reordered stream begins with, or trimming the priming samples an audio encoder
emits. Matroska has no such box, so what the list says is applied to the
timestamps instead.
"""

nbSave
