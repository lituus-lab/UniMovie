# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Matroska and WebM, which are the same format under two names: WebM is
## Matroska restricted to a handful of royalty-free codecs.
##
## The container is EBML — a binary cousin of XML, where every element is an
## identifier, a length and a payload, and elements nest. Both the identifier
## and the length are variable width, encoded by counting leading bits, which
## is the whole of what makes the format awkward to read and compact to write.
##
## Nothing here decodes. A track reports the codec identifier the file carries —
## `V_MPEG4/ISO/AVC`, `V_VP9`, `A_OPUS` — shortened to the four-character form
## the rest of this library speaks, and the coded bytes belong to a backend.

import contracts
import std/strutils
import ./types

const
  MaxElementBytes = 1 shl 30
    ## An element claiming more than a gigabyte is refused rather than trusted;
    ## the ones this reader descends into are headers, not media.

type Cursor = object
  ## A position in the file, with the end of the element being read. Matroska
  ## nests by length rather than by a terminator, so every read is bounded by
  ## its parent and a child cannot escape it.
  data: string
  at: int
  limit: int

func atEnd(cursor: Cursor): bool = cursor.at >= cursor.limit

proc readId(cursor: var Cursor): int64 =
  ## An element identifier, 1 to 4 bytes.
  ##
  ## The leading bits give the width: `1xxxxxxx` is one byte, `01xxxxxx` two,
  ## and so on. Unlike a length, the marker bit is **kept** — the identifier of
  ## `Segment` really is 0x18538067, marker included, which is why the two
  ## readers differ by that one detail.
  if cursor.at >= cursor.limit: return -1
  let first = uint8(cursor.data[cursor.at])
  if first == 0: return -1
  var width = 1
  while width <= 4 and (first and uint8(0x80 shr (width - 1))) == 0: inc width
  if width > 4 or cursor.at + width > cursor.limit: return -1
  result = 0
  for index in 0 ..< width:
    result = (result shl 8) or int64(uint8(cursor.data[cursor.at + index]))
  cursor.at += width

proc readSize(cursor: var Cursor): int64 =
  ## An element length, 1 to 8 bytes.
  ##
  ## Same leading-bit trick as an identifier, but the marker bit is stripped.
  ## An all-ones payload means "unknown length", which a live recording uses
  ## for its Segment; that is reported as -1 and the caller reads to the end of
  ## the parent instead.
  if cursor.at >= cursor.limit: return -1
  let first = uint8(cursor.data[cursor.at])
  if first == 0: return -1
  var width = 1
  while width <= 8 and (first and uint8(0x80 shr (width - 1))) == 0: inc width
  if width > 8 or cursor.at + width > cursor.limit: return -1
  var value = int64(first and uint8(0xFF shr width))
  var unknown = value == int64((1 shl (7 - width + 1)) - 1)
  for index in 1 ..< width:
    let byteValue = uint8(cursor.data[cursor.at + index])
    if byteValue != 0xFF: unknown = false
    value = (value shl 8) or int64(byteValue)
  cursor.at += width
  if unknown: -1 else: value

func readUInt(cursor: Cursor; at, size: int): int64 =
  ## An unsigned integer payload, big-endian in however many bytes the element
  ## declared — Matroska stores 1 in one byte and 1000 in two.
  result = 0
  for index in 0 ..< size:
    result = (result shl 8) or int64(uint8(cursor.data[at + index]))

func readFloat(cursor: Cursor; at, size: int): float =
  ## A float payload, 4 or 8 bytes, IEEE 754 big-endian. Any other width is
  ## malformed and reads as zero rather than as a wild value.
  if size == 4:
    var bits = 0'u32
    for index in 0 .. 3:
      bits = (bits shl 8) or uint32(uint8(cursor.data[at + index]))
    float(cast[float32](bits))
  elif size == 8:
    var bits = 0'u64
    for index in 0 .. 7:
      bits = (bits shl 8) or uint64(uint8(cursor.data[at + index]))
    cast[float64](bits)
  else: 0.0

func readText(cursor: Cursor; at, size: int): string =
  ## A string payload. Matroska pads with trailing zeros, which are not part of
  ## the value.
  cursor.data[at ..< at + size].strip(chars = {'\0'})


const
  # The identifiers this reader looks for, marker bits included.
  idEbml = 0x1A45DFA3'i64
  idDocType = 0x4282'i64
  idSegment = 0x18538067'i64
  idInfo = 0x1549A966'i64
  idTimestampScale = 0x2AD7B1'i64
  idDuration = 0x4489'i64
  idTracks = 0x1654AE6B'i64
  idTrackEntry = 0xAE'i64
  idTrackNumber = 0xD7'i64
  idTrackType = 0x83'i64
  idCodecId = 0x86'i64
  idVideo = 0xE0'i64
  idPixelWidth = 0xB0'i64
  idPixelHeight = 0xBA'i64
  idCodecPrivate = 0x63A2'i64
  idCluster = 0x1F43B675'i64
  idSimpleBlock = 0xA3'i64
  idBlockGroup = 0xA0'i64
  idBlock = 0xA1'i64

iterator elements(cursor: var Cursor): tuple[id: int64; at, size: int] =
  ## Each child element at this level, as its identifier and the span of its
  ## payload.
  ##
  ## An element of unknown length runs to the end of its parent, which is what a
  ## Segment written by a live recorder declares. A length that overruns the
  ## parent ends the walk rather than raising: a truncated download should cost
  ## the caller the elements after the damage, not the ones before it.
  while not cursor.atEnd:
    let id = cursor.readId()
    if id < 0: break
    var size = cursor.readSize()
    if size < 0: size = int64(cursor.limit - cursor.at)
    if size > MaxElementBytes or cursor.at + int(size) > cursor.limit: break
    yield (id, cursor.at, int(size))
    cursor.at += int(size)

func shortCodec(codecId: string): string =
  ## Matroska's codec identifiers are long strings; the rest of this library
  ## speaks the four-character codes MP4 uses, so a caller registers one backend
  ## per codec rather than one per container.
  ##
  ## An identifier with no MP4 equivalent is passed through unchanged, because
  ## inventing a code would be worse than reporting the one the file gave.
  case codecId
  of "V_MPEG4/ISO/AVC": "avc1"
  of "V_MPEGH/ISO/HEVC": "hvc1"
  of "V_AV1": "av01"
  of "V_VP8": "vp08"
  of "V_VP9": "vp09"
  of "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP": "mp4v"
  of "V_THEORA": "theo"
  of "A_AAC": "mp4a"
  of "A_OPUS": "Opus"
  of "A_VORBIS": "vorb"
  of "A_FLAC": "fLaC"
  of "A_MPEG/L3": "mp4a"
  of "A_PCM/INT/LIT", "A_PCM/INT/BIG": "lpcm"
  else: codecId

proc parseTrackEntry(data: string; at, size: int): Track =
  ## One TrackEntry: its number, what it carries, its codec, and — for video —
  ## the pixel dimensions.
  ##
  ## Matroska has no per-track timescale: every timestamp in the file is in the
  ## Segment's units, so the caller copies that in afterwards.
  var cursor = Cursor(data: data, at: at, limit: at + size)
  result.kind = tkOther
  for id, elementAt, elementSize in cursor.elements:
    case id
    of idTrackNumber: result.id = int(cursor.readUInt(elementAt, elementSize))
    of idTrackType:
      # 1 video, 2 audio, 3 complex, 16 logo, 17 subtitle, 18 buttons, 32 control
      result.kind = case cursor.readUInt(elementAt, elementSize)
        of 1: tkVideo
        of 2: tkAudio
        else: tkOther
    of idCodecId: result.codec = shortCodec(cursor.readText(elementAt, elementSize))
    of idVideo:
      var video = Cursor(data: data, at: elementAt, limit: elementAt + elementSize)
      for videoId, videoAt, videoSize in video.elements:
        case videoId
        of idPixelWidth:
          let width = int(video.readUInt(videoAt, videoSize))
          if width in 1 .. MaxDimension: result.width = width
        of idPixelHeight:
          let height = int(video.readUInt(videoAt, videoSize))
          if height in 1 .. MaxDimension: result.height = height
        else: discard
    else: discard

proc readMatroska*(data: string): Movie {.contractual.} =
  ## Demultiplex a Matroska or WebM file: its doc type, its timescale and
  ## duration, and every track with its codec and shape.
  ##
  ## Reads the header elements only — Info, Tracks and Cues — so the cost is
  ## those rather than the file. Clusters, where the media lives, are not walked.
  ##
  ## Nothing is required of the caller: every byte comes from a file, so the
  ## checks are in the body and raise `MovieError`.
  ensure:
    result.tracks.len > 0
  body:
    if data.len < 4: raise newException(MovieError, "mkv: too short to be a file")
    var top = Cursor(data: data, at: 0, limit: data.len)
    var sawEbml = false
    var segmentAt = -1
    var segmentSize = 0
    result.format = "matroska"
    for id, at, size in top.elements:
      if id == idEbml:
        sawEbml = true
        var header = Cursor(data: data, at: at, limit: at + size)
        for headerId, headerAt, headerSize in header.elements:
          if headerId == idDocType:
            let docType = header.readText(headerAt, headerSize)
            if docType notin ["matroska", "webm"]:
              raise newException(MovieError,
                "mkv: doc type is " & docType & ", not matroska or webm")
            result.format = docType
      elif id == idSegment:
        segmentAt = at
        segmentSize = size
        break
    if not sawEbml: raise newException(MovieError, "mkv: no EBML header")
    if segmentAt < 0: raise newException(MovieError, "mkv: no segment")

    # Matroska counts time in nanoseconds scaled by TimestampScale, which is
    # 1000000 in every file anyone writes — a millisecond. Reported as a
    # timescale in the ISOBMFF sense so both containers answer the same way.
    var scaleNs = 1_000_000'i64
    var durationTicks = 0.0
    var segment = Cursor(data: data, at: segmentAt, limit: segmentAt + segmentSize)
    for id, at, size in segment.elements:
      case id
      of idInfo:
        var info = Cursor(data: data, at: at, limit: at + size)
        for infoId, infoAt, infoSize in info.elements:
          case infoId
          of idTimestampScale:
            let scale = info.readUInt(infoAt, infoSize)
            if scale > 0: scaleNs = scale
          of idDuration: durationTicks = info.readFloat(infoAt, infoSize)
          else: discard
      of idTracks:
        var tracks = Cursor(data: data, at: at, limit: at + size)
        for trackId, trackAt, trackSize in tracks.elements:
          if trackId != idTrackEntry: continue
          if result.tracks.len >= MaxTracks:
            raise newException(MovieError, "mkv: implausible track count")
          result.tracks.add parseTrackEntry(data, trackAt, trackSize)
      else: discard

    if result.tracks.len == 0: raise newException(MovieError, "mkv: no track")
    result.timescale = int(1_000_000_000'i64 div scaleNs)
    if result.timescale <= 0: result.timescale = 1000
    result.duration = int64(durationTicks)
    if result.duration < 0: result.duration = 0
    for track in result.tracks.mitems:
      # Every timestamp in a Matroska file is in the segment's units.
      track.timescale = result.timescale
      track.duration = result.duration

proc readMatroskaFile*(path: string): Movie {.contractual.} =
  ## `readMatroska` over a file. A path that cannot be opened raises `IOError`,
  ## which is what separates a missing file from a malformed one.
  require:
    path.len > 0
  body:
    readMatroska(readFile(path))




# The media, which the header walk above deliberately skips. A Cluster holds
# blocks, a block holds one frame or several laced together, and neither the
# count nor the position of any of it is indexed outside the Cues — so reaching
# sample n costs a walk from the first Cluster.

proc frameSpans(data: string; at, limit: int):
    tuple[track: int; spans: seq[Slice[int]]] =
  ## The track number a block belongs to and where each of its frames sits.
  ##
  ## A block is a track number, a signed relative timestamp, a flags byte and
  ## then the frames. Bits 1-2 of the flags say how several frames share one
  ## block — Matroska calls it lacing, and it exists because a block header per
  ## frame is a real cost on audio, where a frame can be twenty bytes.
  ##
  ## A malformed size ends the block at the frames read so far rather than
  ## raising: the frames before the damage are still exactly what the file
  ## holds.
  var cursor = Cursor(data: data, at: at, limit: limit)
  let track = cursor.readSize()
  if track < 0: return (-1, @[])
  if cursor.at + 3 > limit: return (-1, @[])
  cursor.at += 2 # the timestamp, relative to the cluster's, unused here
  let flags = uint8(data[cursor.at])
  inc cursor.at
  result.track = int(track)

  let lacing = (flags shr 1) and 0x03
  if lacing == 0:
    if cursor.at < limit: result.spans.add cursor.at ..< limit
    return
  if cursor.at >= limit: return
  let count = int(uint8(data[cursor.at])) + 1
  inc cursor.at

  var sizes = newSeq[int](count)
  case lacing
  of 1:
    # Xiph: each size but the last as a run of 255s ending in a smaller byte.
    for index in 0 ..< count - 1:
      var size = 0
      while cursor.at < limit:
        let piece = int(uint8(data[cursor.at]))
        inc cursor.at
        size += piece
        if piece != 255: break
      sizes[index] = size
  of 2:
    # Fixed: the frames divide the rest evenly, so only the count is stored.
    let rest = limit - cursor.at
    if count == 0 or rest mod count != 0: return
    for index in 0 ..< count: sizes[index] = rest div count
  of 3:
    # EBML: the first size outright, each next one as a signed difference from
    # the one before, which keeps a run of similar frames to a byte apiece.
    let first = cursor.readSize()
    if first < 0: return
    sizes[0] = int(first)
    for index in 1 ..< count - 1:
      let width = block:
        if cursor.at >= limit: return
        let lead = uint8(data[cursor.at])
        if lead == 0: return
        var found = 1
        while found <= 8 and (lead and uint8(0x80 shr (found - 1))) == 0: inc found
        found
      let raw = cursor.readSize()
      if raw < 0: return
      # Signed: the range is centred, so the bias is half of what the width holds.
      let bias = (1'i64 shl (7 * width - 1)) - 1
      sizes[index] = sizes[index - 1] + int(raw - bias)
      if sizes[index] < 0: return
  else: return

  var used = 0
  for index in 0 ..< count - 1: used += sizes[index]
  if lacing != 2:
    let rest = limit - cursor.at - used
    if rest < 0: return
    sizes[count - 1] = rest

  for size in sizes:
    if size < 0 or cursor.at + size > limit: return
    result.spans.add cursor.at ..< cursor.at + size
    cursor.at += size

iterator trackFrames(data: string; trackNumber: int): Slice[int] =
  ## Every frame of one track, in the order the file stores them.
  ##
  ## Clusters are walked in file order and blocks within them likewise, which
  ## is decode order — not display order. A stream with B-frames comes back
  ## reordered, exactly as a decoder wants it.
  var top = Cursor(data: data, at: 0, limit: data.len)
  for id, at, size in top.elements:
    if id != idSegment: continue
    var segment = Cursor(data: data, at: at, limit: at + size)
    for segmentId, segmentAt, segmentSize in segment.elements:
      if segmentId != idCluster: continue
      var cluster = Cursor(data: data, at: segmentAt,
                           limit: segmentAt + segmentSize)
      for clusterId, blockAt, blockSize in cluster.elements:
        var payload = -1 .. -1
        if clusterId == idSimpleBlock:
          payload = blockAt ..< blockAt + blockSize
        elif clusterId == idBlockGroup:
          var group = Cursor(data: data, at: blockAt,
                             limit: blockAt + blockSize)
          for groupId, groupAt, groupSize in group.elements:
            if groupId == idBlock:
              payload = groupAt ..< groupAt + groupSize
              break
        if payload.a < 0: continue
        let found = frameSpans(data, payload.a, payload.b + 1)
        if found.track != trackNumber: continue
        for span in found.spans: yield span
    break

proc trackNumbers(data: string): seq[int] =
  ## The container's own track numbers, in the order `readMatroska` reports the
  ## tracks — a block names its track by number, and a caller counts positions.
  var top = Cursor(data: data, at: 0, limit: data.len)
  for id, at, size in top.elements:
    if id != idSegment: continue
    var segment = Cursor(data: data, at: at, limit: at + size)
    for segmentId, segmentAt, segmentSize in segment.elements:
      if segmentId != idTracks: continue
      var tracks = Cursor(data: data, at: segmentAt,
                          limit: segmentAt + segmentSize)
      for trackId, trackAt, trackSize in tracks.elements:
        if trackId != idTrackEntry: continue
        var entry = Cursor(data: data, at: trackAt, limit: trackAt + trackSize)
        for entryId, entryAt, entrySize in entry.elements:
          if entryId == idTrackNumber:
            result.add int(entry.readUInt(entryAt, entrySize))
            break
    break

proc codedSample*(data: string; trackIndex, sampleIndex: int): string
    {.contractual.} =
  ## The coded bytes of one frame, exactly as the file holds them.
  ##
  ## Costs a walk from the first Cluster to that frame, because Matroska
  ## indexes nothing outside its Cues — where ISO base media reads an offset
  ## from a table. A caller taking every frame in turn should expect the walk
  ## each time.
  require:
    trackIndex >= 0
    sampleIndex >= 0
  body:
    let numbers = trackNumbers(data)
    if trackIndex >= numbers.len:
      raise newException(MovieError, "mkv: track index past the file")
    var seen = 0
    for span in trackFrames(data, numbers[trackIndex]):
      if seen == sampleIndex: return data[span]
      inc seen
    raise newException(MovieError, "mkv: sample index past the track")

proc codedSampleCount*(data: string; trackIndex: int): int {.contractual.} =
  ## How many frames a track holds.
  ##
  ## Not on `Track`, and not filled by `readMatroska`: it is the same full walk
  ## as `codedSample`, which a caller asking only for a file's shape should not
  ## pay for.
  require:
    trackIndex >= 0
  ensure:
    result >= 0
  body:
    let numbers = trackNumbers(data)
    if trackIndex >= numbers.len:
      raise newException(MovieError, "mkv: track index past the file")
    for span in trackFrames(data, numbers[trackIndex]): inc result


