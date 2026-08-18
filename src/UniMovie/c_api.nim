# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The C ABI. Built --app:staticlib/--app:lib --noMain --mm:arc -d:release.
## Keep in sync with include/UniMovie.h; tests/c links the header against the
## library, so a header that drifts fails to compile rather than at a caller.
##
## No Nim exception crosses this boundary: every entry point returns a status
## and puts the reason in `umov_last_error`. Out-of-range input is rejected,
## never clamped into range.

import ./types
import ./isobmff

const UniMovieVersion = "0.1.0"

type MovieStatus = enum
  umovOk = 0
  umovErrArg = 1
  umovErrIo = 2
  umovErrFormat = 3

var lastError {.threadvar.}: string

proc umov_version(): cstring {.exportc, cdecl, dynlib.} =
  ## Static version string; do not free.
  cstring(UniMovieVersion)

proc umov_last_error(): cstring {.exportc, cdecl, dynlib.} =
  ## Most recent failure on this thread, "" when there is none.
  cstring(lastError)

proc umov_probe(path: cstring; trackCount, videoIndex, audioIndex: ptr cint;
                durationSeconds: ptr cdouble): cint
    {.exportc, cdecl, dynlib.} =
  ## Shape of a container: how many tracks, which is the first video and audio
  ## one (-1 when absent), and the movie's playing time in seconds.
  if path == nil or trackCount == nil or videoIndex == nil or
      audioIndex == nil or durationSeconds == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  try:
    let movie = readMovieFile($path)
    trackCount[] = cint(movie.tracks.len)
    videoIndex[] = cint(movie.videoTrack)
    audioIndex[] = cint(movie.audioTrack)
    durationSeconds[] = cdouble(
      if movie.timescale > 0: movie.durationSeconds else: 0.0)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

proc umov_track(path: cstring; index: cint; kind: ptr cint;
                codec: ptr array[5, char]; width, height, rotation: ptr cint;
                sampleCount, keyframeCount: ptr cint): cint
    {.exportc, cdecl, dynlib.} =
  ## One track's shape. `kind` is 0 video, 1 audio, 2 other. `codec` receives
  ## the container's own four-character code and a terminating zero, so the
  ## caller supplies five bytes. `rotation` is clockwise **degrees** — 0, 90,
  ## 180 or 270, not an ordinal — and ffprobe counts the same matrix
  ## anticlockwise, so its 90 is this library's 270.
  if path == nil or kind == nil or codec == nil or width == nil or
      height == nil or rotation == nil or sampleCount == nil or
      keyframeCount == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  if index < 0:
    lastError = "track index must not be negative"
    return cint(umovErrArg)
  try:
    let movie = readMovieFile($path)
    if int(index) >= movie.tracks.len:
      lastError = "track index past the file"
      return cint(umovErrArg)
    let track = movie.tracks[int(index)]
    kind[] = cint(ord(track.kind))
    for position in 0 .. 4: codec[][position] = '\0'
    for position in 0 ..< min(4, track.codec.len):
      codec[][position] = track.codec[position]
    width[] = cint(track.width)
    height[] = cint(track.height)
    rotation[] = cint(ord(track.rotation))
    sampleCount[] = cint(track.sampleCount)
    keyframeCount[] = cint(track.keyframes.len)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)


