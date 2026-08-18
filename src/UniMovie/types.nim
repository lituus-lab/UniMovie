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
  MaxWriterTracks* = 8
    ## More than a muxer built for a camera or a renderer needs. A caller
    ## asking for more is refused rather than allocated for. Here rather than
    ## beside either writer, because both bound themselves by it and two copies
    ## would be free to drift apart.
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
    width*, height*: int
      ## How wide and tall the track should be **displayed**, in pixels; video
      ## only. Not always what the decoder produces: a track whose pixels are
      ## not square says so, and the two differ by that ratio.
    codedWidth*, codedHeight*: int
      ## How many pixels the decoder produces, from the sample entry; video
      ## only, and 0 where the container does not say.
      ##
      ## **This is the pair to compare with a decoded frame**, and the one
      ## `ffprobe`'s `width`/`height` report. A file with a 16:15 sample aspect
      ## is 718 pixels wide and 765 wide on screen, and using the wrong one
      ## stretches every thumbnail made from it.
    rotation*: Rotation
    sampleCount*: int
      ## Coded samples in the track, or 0 when the container does not say.
      ##
      ## **Zero means unknown, not empty.** ISO base media and AVI count them
      ## from their own tables and Ogg from its packets; Matroska and MPEG-TS
      ## keep the count nowhere but in the media itself, which this reader does
      ## not walk. A caller asking "is there anything here" should look at the
      ## duration.
    keyframes*: seq[int]
      ## Indices into the sample table at which decoding may start, ascending.
      ##
      ## **Empty means unknown, not none.** Only ISO base media reports them,
      ## from `stss` — and there an absent table means every sample is a
      ## keyframe, so the sequence is filled rather than left empty. For every
      ## other container it stays empty, because the index lives where this
      ## reader does not go: Matroska's Cues, AVI's per-chunk flags, a transport
      ## stream's random-access indicator.

  Edit* = object
    ## One entry of a track's edit list: which stretch of its media plays, and
    ## for how long on the presentation clock.
    ##
    ## Two shapes cover almost every real use. An **empty edit** — `mediaTime`
    ## of -1 — holds the track blank for `duration`, which is how a track that
    ## starts late stays in sync with one that does not. A **trim** —
    ## `mediaTime` of *n* — starts playback *n* units into the media, which is
    ## how an encoder's own priming samples are kept out of what is heard.
    ##
    ## The media rate is always 1. A rate other than 1 asks a player to
    ## resample, which is a decision about the content rather than about the
    ## container, and leaving it out means no caller writes 0 by forgetting to
    ## set it.
    duration*: int64
      ## How long this edit lasts, in the **movie** timescale — milliseconds.
      ## Zero means the rest of the track: the whole media duration for a trim,
      ## which a caller cannot compute before the last sample is written.
    mediaTime*: int64
      ## Where in the media this edit starts, in the **track's** timescale, or
      ## -1 for an empty edit that plays nothing.

  TrackParams* = object
    ## What a track is, before any sample of it exists.
    kind*: TrackKind
    codec*: string
      ## The four-character code the sample entry is named after — `avc1`,
      ## `hvc1`, `av01`, `mp4a`, `alac`. It is what a reader reports and what a
      ## decoder backend is registered under, so it must match the bytes.
    timescale*: int
      ## Units per second every timestamp of this track is counted in. A video
      ## track usually takes the frame rate times a small factor so that a
      ## variable frame interval stays exact; audio takes the sample rate.
    width*, height*: int ## pixels; video only
    channels*: int ## audio only
    sampleRate*: int ## audio only, in hertz
    configKind*: string
      ## The four-character name of the codec configuration box inside the
      ## sample entry — `avcC` for H.264, `hvcC` for HEVC, `av1C` for AV1,
      ## `esds` for AAC, `alac` for Apple Lossless. Empty writes no such box,
      ## which suits a codec that needs none.
    config*: string
      ## That box's payload, exactly as the encoder produced it. Never parsed
      ## here: a parameter set is the decoder's business, and copying it
      ## unexamined is what keeps this a muxer.
    edits*: seq[Edit]
      ## The track's edit list, or empty for none — which is what a track whose
      ## media starts at zero and plays through wants, and writes no `edts` box
      ## at all.

  Movie* = object
    ## Everything a probe reports about a file.
    format*: string  ## container brand, e.g. "mp4", "mov", "matroska"
    timescale*: int  ## the movie's own units per second
    duration*: int64 ## in `timescale` units
    tracks*: seq[Track]

func durationSeconds*(track: Track): float {.contractual.} =
  ## The track's playing time in seconds, or 0 when the container declared no
  ## timescale.
  ##
  ## Checked in the body rather than by a precondition: the timescale comes from
  ## the file, so a header that omits it is a fact about the file and not a
  ## caller's mistake. A precondition would raise in debug and divide by zero in
  ## release, which is the worst of both.
  ensure:
    result >= 0.0
  body:
    if track.timescale <= 0: 0.0
    else: float(track.duration) / float(track.timescale)

func durationSeconds*(movie: Movie): float {.contractual.} =
  ## The movie's playing time in seconds, from its own header rather than from
  ## the longest track: a file may declare a duration that outlasts its media,
  ## and the header is what a player honours. Zero when the header is missing —
  ## see the track overload for why that is not a precondition.
  ensure:
    result >= 0.0
  body:
    if movie.timescale <= 0: 0.0
    else: float(movie.duration) / float(movie.timescale)

func videoTrack*(movie: Movie): int {.contractual.} =
  ## The index of the first video track, or -1 when there is none. First rather
  ## than largest: containers list the primary presentation first, and a file
  ## with a thumbnail track would otherwise report the thumbnail.
  ##
  ## The postcondition is what makes the -1 convention safe: any other result
  ## indexes `tracks`, so a caller needs one comparison and no bounds check.
  ensure:
    result == -1 or result in 0 ..< movie.tracks.len
  body:
    result = -1
    for index, track in movie.tracks:
      if track.kind == tkVideo: return index

func audioTrack*(movie: Movie): int {.contractual.} =
  ## The index of the first audio track, or -1 when there is none. As above,
  ## any result other than -1 indexes `tracks`.
  ensure:
    result == -1 or result in 0 ..< movie.tracks.len
  body:
    result = -1
    for index, track in movie.tracks:
      if track.kind == tkAudio: return index




