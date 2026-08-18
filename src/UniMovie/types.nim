# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## What a demuxer reports, and the ceilings every reader checks against.
##
## One shape for every container: a file is a list of tracks, each with a codec
## name, a timescale and a duration, and a video track additionally with pixel
## dimensions and a rotation. What differs between MP4, Matroska and AVI is how
## those numbers are stored, never what they mean.

import contracts

const
  MaxTracks* = 1024
    ## More than any real file carries. A header claiming more is refused
    ## rather than allocated.
  MaxSamples* = 1 shl 24
    ## Sixteen million coded samples is many hours of video. A sample table
    ## claiming more is refused rather than allocated.
  MaxDimension* = 1_000_000
    ## Past any real frame. A header claiming more is refused rather than
    ## believed, which is what stops a corrupt file from being reported as an
    ## image a million pixels across.

type
  MovieError* = object of CatchableError
    ## A container this library cannot read, a truncated file, or a track
    ## whose declared shape contradicts what the file holds.

  TrackKind* = enum
    ## What a track carries. `tkOther` covers subtitles, timecode and data
    ## tracks: they are reported so a caller sees the whole file, and skipped
    ## by anything asking for pictures or sound.
    tkVideo = "video"
    tkAudio = "audio"
    tkOther = "other"

  Rotation* = enum
    ## Clockwise display rotation, from the track's transformation matrix.
    ## Phones record sideways and correct it here rather than in the pixels, so
    ## a player that ignores this shows a quarter of a library on its side.
    ##
    ## **Clockwise, where ffprobe counts counter-clockwise.** A file ffprobe
    ## reports as `rotation=90` reads here as `rot270`, and the two agree: they
    ## describe the same matrix from opposite directions. Anything migrating off
    ## `ffprobe` has to negate, or it will rotate twice in the wrong direction.
    rot0 = 0
    rot90 = 90
    rot180 = 180
    rot270 = 270

  Track* = object
    ## One track's shape. `id` is the container's own identifier, kept so a
    ## caller can ask for a sample from this track by name rather than by
    ## position.
    id*: int
    kind*: TrackKind
    codec*: string ## the container's own code, e.g. "avc1", "hvc1", "av01"
    timescale*: int ## units per second the durations below are in
    duration*: int64 ## in `timescale` units; 0 when the file does not say
    width*, height*: int ## pixels, video only
    rotation*: Rotation
    sampleCount*: int
    keyframes*: seq[int] ## indices into the sample table, ascending

  Movie* = object
    ## Everything a probe reports about a file.
    format*: string  ## container brand, e.g. "mp4", "mov", "matroska"
    timescale*: int  ## the movie's own units per second
    duration*: int64 ## in `timescale` units
    tracks*: seq[Track]

func durationSeconds*(track: Track): float {.contractual.} =
  ## The track's playing time. Zero when the container declared no duration,
  ## which is legal for a stream that was still being written.
  require:
    track.timescale > 0
  body:
    float(track.duration) / float(track.timescale)

func durationSeconds*(movie: Movie): float {.contractual.} =
  ## The movie's playing time, from its own header rather than from the longest
  ## track: a file may declare a duration that outlasts its media, and the
  ## header is what a player honours.
  require:
    movie.timescale > 0
  body:
    float(movie.duration) / float(movie.timescale)

func videoTrack*(movie: Movie): int =
  ## The index of the first video track, or -1 when there is none. First rather
  ## than largest: containers list the primary presentation first, and a file
  ## with a thumbnail track would otherwise report the thumbnail.
  result = -1
  for index, track in movie.tracks:
    if track.kind == tkVideo: return index

func audioTrack*(movie: Movie): int =
  ## The index of the first audio track, or -1 when there is none.
  result = -1
  for index, track in movie.tracks:
    if track.kind == tkAudio: return index


