# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## AVI: RIFF chunks, little-endian, from 1992 and still coming out of old
## camcorders and screen recorders.
##
## A file is `RIFF`, a size, the form type `AVI `, then chunks. `LIST hdrl`
## holds the main header and one `LIST strl` per stream; each of those has a
## stream header (`strh`) saying what the stream is and how fast, and a stream
## format (`strf`) which for video is a Windows `BITMAPINFOHEADER`.
##
## Nothing here decodes. A stream reports the four-character handler the file
## names — `xvid`, `mp4v`, `MJPG` — and the bytes belong to a backend.

import contracts
import std/strutils
import ./types

type Cursor = object
  ## A position in the file and the end of the list being read. RIFF nests by
  ## length, so a chunk cannot escape its parent.
  data: string
  at: int
  limit: int

func leU16(data: string; at: int): int =
  ## Two little-endian bytes. RIFF is little-endian throughout, the opposite of
  ## ISOBMFF.
  int(uint8(data[at])) or (int(uint8(data[at + 1])) shl 8)

func scaledDuration(units, scale: int64; what: string): int64 =
  ## `units * scale`, refusing a product no `int64` holds.
  ##
  ## Both factors come from 32-bit header fields, so a file is free to claim
  ## four billion frames at four billion microseconds each. That product is
  ## past `int64`, and an unchecked build wraps it silently into a negative
  ## duration rather than stopping — which is why this is a check and not an
  ## overflow trap.
  if units != 0 and scale > high(int64) div units:
    raise newException(MovieError, "avi: implausible " & what)
  units * scale

func leU32(data: string; at: int): int64 =
  ## Four little-endian bytes, widened so a size near 2^32 stays positive.
  result = 0
  for index in countdown(3, 0):
    result = (result shl 8) or int64(uint8(data[at + index]))

func fourCC(data: string; at: int): string =
  ## The four-character code at `at`, as written.
  data[at ..< at + 4]

iterator chunks(cursor: var Cursor): tuple[id: string; at, size: int] =
  ## Each chunk at this level, as its identifier and the span of its payload.
  ##
  ## Chunks are word-aligned: an odd size is followed by one pad byte that is
  ## not part of either chunk. A size that overruns the parent ends the walk
  ## rather than raising, so a truncated file still yields what came before it.
  while cursor.at + 8 <= cursor.limit:
    let id = fourCC(cursor.data, cursor.at)
    let size = leU32(cursor.data, cursor.at + 4)
    let body = cursor.at + 8
    # Bounded by what the parent actually holds, not by a fixed ceiling. The
    # file is already in memory, so the parent span is the real limit; a
    # `LIST movi` past a gigabyte is an ordinary recording, and refusing it
    # would end the walk and report a file with no frames in it. Compared
    # before the conversion, so a declared size no `int` holds cannot wrap.
    if size < 0 or size > int64(cursor.limit - body): break
    yield (id, body, int(size))
    cursor.at = body + int(size) + (int(size) and 1)

proc parseStrl(data: string; at, size: int): Track =
  ## One `LIST strl`: what the stream is, its codec, its rate, and — for video —
  ## the dimensions from its `BITMAPINFOHEADER`.
  var cursor = Cursor(data: data, at: at, limit: at + size)
  result.kind = tkOther
  var scale = 0'i64
  var rate = 0'i64
  var length = 0'i64
  for id, chunkAt, chunkSize in cursor.chunks:
    case id
    of "strh":
      if chunkSize < 40: continue
      # fccType, fccHandler, flags, priority, language, initialFrames, scale,
      # rate, start, length — the two that matter are scale and rate, whose
      # quotient is the sample rate.
      case fourCC(data, chunkAt)
      of "vids": result.kind = tkVideo
      of "auds": result.kind = tkAudio
      else: result.kind = tkOther
      let handler = fourCC(data, chunkAt + 4).strip(chars = {'\0', ' '})
      if handler.len == 4: result.codec = handler
      scale = leU32(data, chunkAt + 20)
      rate = leU32(data, chunkAt + 24)
      length = leU32(data, chunkAt + 32)
    of "strf":
      if result.kind == tkVideo and chunkSize >= 40:
        # BITMAPINFOHEADER: size, width, height, planes, bitCount, compression.
        # Height is signed and negative for a top-down image, which is a
        # storage direction and not a different size.
        let width = int(leU32(data, chunkAt + 4))
        let height = int(cast[int32](uint32(leU32(data, chunkAt + 8) and
          0xFFFF_FFFF)))
        if width in 1 .. MaxDimension: result.width = width
        if abs(height) in 1 .. MaxDimension: result.height = abs(height)
        let compression = fourCC(data, chunkAt + 16).strip(chars = {'\0', ' '})
        # The handler in strh is often empty or a duplicate; the compression
        # code in the format header is the one that names the codec.
        if compression.len == 4: result.codec = compression
      elif result.kind == tkAudio and chunkSize >= 16:
        # WAVEFORMATEX: the format tag is a number, not a code, so it is
        # rendered as four hex digits rather than invented into a name.
        let tag = leU16(data, chunkAt)
        if result.codec.len == 0: result.codec = toHex(tag, 4)
    else: discard
  if scale > 0 and rate > 0:
    result.timescale = int(rate)
    result.duration = scaledDuration(length, scale, "stream duration")
  result.sampleCount = int(length)

proc readAvi*(data: string): Movie {.contractual.} =
  ## Demultiplex an AVI file: its streams, their codecs, shapes and durations.
  ##
  ## Reads `hdrl` only, so the cost is the header rather than the file. The
  ## index (`idx1`) is not walked: AVI has no notion of a sync-sample table, and
  ## a keyframe index would have to come from the per-chunk flags in `movi`.
  ##
  ## Nothing is required of the caller: every byte comes from a file, so the
  ## checks are in the body and raise `MovieError`.
  ensure:
    result.tracks.len > 0
  body:
    if data.len < 12: raise newException(MovieError, "avi: too short to be a file")
    if fourCC(data, 0) != "RIFF" or fourCC(data, 8) != "AVI ":
      raise newException(MovieError, "avi: not a RIFF AVI file")
    result.format = "avi"

    var top = Cursor(data: data, at: 12, limit: data.len)
    for id, at, size in top.chunks:
      if id != "LIST" or size < 4 or fourCC(data, at) != "hdrl": continue
      var hdrl = Cursor(data: data, at: at + 4, limit: at + size)
      for listId, listAt, listSize in hdrl.chunks:
        case listId
        of "avih":
          if listSize < 32: continue
          # microSecPerFrame, maxBytesPerSec, padding, flags, totalFrames,
          # initialFrames, streams, bufferSize, width, height.
          let microsPerFrame = leU32(data, listAt)
          let totalFrames = leU32(data, listAt + 16)
          if microsPerFrame > 0:
            # Reported in microseconds so the duration stays exact: a frame
            # rate of 29.97 is 33367 microseconds, which no integer timescale
            # in seconds represents.
            result.timescale = 1_000_000
            result.duration = scaledDuration(totalFrames, microsPerFrame,
                                             "movie duration")
        of "LIST":
          if listSize < 4 or fourCC(data, listAt) != "strl": continue
          if result.tracks.len >= MaxTracks:
            raise newException(MovieError, "avi: implausible stream count")
          result.tracks.add parseStrl(data, listAt + 4, listSize - 4)
        else: discard
      break

    if result.tracks.len == 0: raise newException(MovieError, "avi: no stream")
    if result.timescale <= 0:
      # No usable main header: fall back to the first video stream's own rate,
      # so a duration is still reported rather than silently zero.
      for track in result.tracks:
        if track.kind == tkVideo and track.timescale > 0:
          result.timescale = track.timescale
          result.duration = track.duration
          break

proc readAviFile*(path: string): Movie {.contractual.} =
  ## `readAvi` over a file. A path that cannot be opened raises `IOError`,
  ## which is what separates a missing file from a malformed one.
  require:
    path.len > 0
  body:
    readAvi(readFile(path))




# The media, which the header walk above deliberately skips. It sits in
# `LIST movi` as one chunk per frame, named for the stream it belongs to:
# `00dc` is stream 0, compressed video; `01wb` is stream 1, audio.

func carriesMedia(id: string): bool =
  ## Whether a chunk name says it holds media rather than control.
  ##
  ## `db` and `dc` are video frames, uncompressed and compressed; `wb` is
  ## audio. `pc` is a palette change — it belongs to the stream and is not a
  ## sample of it, so returning one as a coded frame would hand a caller
  ## bytes no decoder asked for.
  ##
  ## Matched without regard to case, since a muxer is free to write `DC`.
  ## This stays a list of what is media rather than of what is not, so an
  ## uppercase `PC` is excluded by the same rule as a lowercase one.
  id.len == 4 and id[2 .. 3].toLowerAscii in ["db", "dc", "wb"]

func streamOf(id: string): int =
  ## The stream a media chunk belongs to, from the two digits its name starts
  ## with, or -1 for a chunk that names no stream. AVI writes the number in
  ## ASCII, so stream 10 really is the characters `1` and `0`.
  if id.len < 4: return -1
  if id[0] notin '0' .. '9' or id[1] notin '0' .. '9': return -1
  (ord(id[0]) - ord('0')) * 10 + (ord(id[1]) - ord('0'))

iterator streamChunks(data: string; stream: int): Slice[int] =
  ## Every media chunk of one stream, in file order.
  ##
  ## Walks `movi` rather than reading `idx1`, because an index's offsets are
  ## written relative to the file in some encoders and to `movi` in others,
  ## with nothing in the file to say which — and a walk cannot be wrong about
  ## it. A file past four gigabytes continues in further `RIFF AVIX` segments,
  ## which are walked as well.
  ##
  ## `LIST rec ` groups the chunks of one frame together for playback off slow
  ## media; it is descended into, since the chunks a caller wants are inside it.
  var top = Cursor(data: data, at: 12, limit: data.len)
  for id, at, size in top.chunks:
    var movi = -1 .. -1
    if id == "LIST" and size >= 4 and fourCC(data, at) == "movi":
      movi = at + 4 ..< at + size
    elif id == "RIFF" and size >= 4 and fourCC(data, at) == "AVIX":
      var extension = Cursor(data: data, at: at + 4, limit: at + size)
      for extId, extAt, extSize in extension.chunks:
        if extId == "LIST" and extSize >= 4 and fourCC(data, extAt) == "movi":
          movi = extAt + 4 ..< extAt + extSize
          break
    if movi.a < 0: continue
    var cursor = Cursor(data: data, at: movi.a, limit: movi.b + 1)
    for chunkId, chunkAt, chunkSize in cursor.chunks:
      if chunkId == "LIST" and chunkSize >= 4 and fourCC(data, chunkAt) == "rec ":
        var group = Cursor(data: data, at: chunkAt + 4,
                           limit: chunkAt + chunkSize)
        for groupId, groupAt, groupSize in group.chunks:
          if streamOf(groupId) == stream and carriesMedia(groupId):
            yield groupAt ..< groupAt + groupSize
      elif streamOf(chunkId) == stream and carriesMedia(chunkId):
        yield chunkAt ..< chunkAt + chunkSize

proc codedSample*(data: string; trackIndex, sampleIndex: int): string
    {.contractual.} =
  ## The coded bytes of one chunk, exactly as the file holds them.
  ##
  ## Costs a walk of `movi` to that chunk. An empty chunk is a real thing in
  ## AVI — it means the frame is unchanged from the one before — and comes back
  ## as an empty string rather than being skipped, so indices keep matching the
  ## stream's own frame numbering.
  require:
    trackIndex >= 0
    sampleIndex >= 0
  body:
    if trackIndex >= readAvi(data).tracks.len:
      raise newException(MovieError, "avi: stream index past the file")
    var seen = 0
    for span in streamChunks(data, trackIndex):
      if seen == sampleIndex: return data[span]
      inc seen
    raise newException(MovieError, "avi: sample index past the stream")

proc codedSampleCount*(data: string; trackIndex: int): int {.contractual.} =
  ## How many media chunks a stream holds.
  ##
  ## `strh` also declares a length, which `readAvi` reports as `sampleCount`;
  ## this is what the file actually contains. The two disagree on a recording
  ## that was cut short, and this one is the number a caller can index up to.
  require:
    trackIndex >= 0
  ensure:
    result >= 0
  body:
    # The index is checked against the header rather than left to yield
    # nothing: a stream that does not exist and one that holds no chunk are
    # different answers, and 0 for both would hide the first.
    if trackIndex >= readAvi(data).tracks.len:
      raise newException(MovieError, "avi: stream index past the file")
    for span in streamChunks(data, trackIndex): inc result


