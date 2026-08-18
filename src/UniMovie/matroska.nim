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
        # One value per entry, whether or not it carries a number: `readMovie`
        # keeps every entry, and a caller addresses a track by its position in
        # that list. Skipping a numberless entry here would shift every track
        # after it onto the wrong samples.
        var number = 0 # no Matroska track is numbered 0, so nothing matches it
        for entryId, entryAt, entrySize in entry.elements:
          if entryId == idTrackNumber:
            number = int(entry.readUInt(entryAt, entrySize))
            break
        result.add number
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


# Writing. The same EBML the reader above walks, assembled rather than parsed.
#
# Matroska keeps one clock for the whole file where ISO base media gives each
# track its own, so a track's timestamps are converted into the segment's
# units on the way in. That conversion is the only place this writer is lossy,
# and at the usual millisecond scale it costs under half a millisecond per
# timestamp.

import std/streams
# Maths comes from UniMath, never std/math: one façade for the family, so a
# rounding rule that has to change changes in one place.
import UniMath/native_float

const
  DefaultTimestampScaleNs = 1_000_000'i64
    ## A millisecond, which is what every file anyone writes uses.
  MaxClusterSpan = 30_000
    ## A block's timestamp is stored as a signed 16-bit offset from its
    ## cluster's, so a cluster cannot span more than 32767 units. Broken well
    ## short of that, since a cluster is also the unit a player seeks to.
  idTrackUid = 0x73C5'i64
  idFlagLacing = 0x9C'i64
  idAudio = 0xE1'i64
  idSamplingFrequency = 0xB5'i64
  idChannels = 0x9F'i64
  idClusterTimestamp = 0xE7'i64
  idMuxingApp = 0x4D80'i64
  idWritingApp = 0x5741'i64
  idEbmlVersion = 0x4286'i64
  idEbmlReadVersion = 0x42F7'i64
  idEbmlMaxIdLength = 0x42F2'i64
  idEbmlMaxSizeLength = 0x42F3'i64
  idDocTypeVersion = 0x4287'i64
  idDocTypeReadVersion = 0x4285'i64
  idCues = 0x1C53BB6B'i64
  idCuePoint = 0xBB'i64
  idCueTime = 0xB3'i64
  idCueTrackPositions = 0xB7'i64
  idCueTrack = 0xF7'i64
  idCueClusterPosition = 0xF1'i64

func idBytes(id: int64): string =
  ## An element identifier, as stored. The constants above already carry their
  ## marker bits, so this only has to write the bytes that are there — which is
  ## why it counts down from the top rather than choosing a width.
  var width = 1
  while width < 8 and (id shr (8 * width)) != 0: inc width
  for index in countdown(width - 1, 0):
    result.add char((id shr (8 * index)) and 0xFF)

func sizeBytes(value: int64; width = 0): string =
  ## An element length. The marker bit is stripped from the value, unlike an
  ## identifier's — the one asymmetry in EBML.
  ##
  ## `width` forces a wider encoding than the value needs, which is how a
  ## length can be patched later without the box changing size.
  var found = max(width, 1)
  if width == 0:
    # An all-ones payload means "unknown", so a value that would encode as all
    # ones needs one byte more.
    while found < 8 and value >= (1'i64 shl (7 * found)) - 1: inc found
  for index in countdown(found - 1, 0):
    var byteValue = (value shr (8 * index)) and 0xFF
    if index == found - 1: byteValue = byteValue or (0x80 shr (found - 1))
    result.add char(byteValue)

func element(id: int64; payload: string): string =
  ## One element: its identifier, its length, its payload.
  idBytes(id) & sizeBytes(int64(payload.len)) & payload

func uintPayload(value: int64): string =
  ## An unsigned integer, in as few bytes as hold it. Matroska stores 1 in one
  ## byte, which is most of why its headers are small.
  if value == 0: return "\0"
  var width = 1
  while width < 8 and (value shr (8 * width)) != 0: inc width
  for index in countdown(width - 1, 0):
    result.add char((value shr (8 * index)) and 0xFF)

func floatPayload(value: float): string =
  ## A float, eight bytes, IEEE 754 big-endian.
  let bits = cast[uint64](value)
  for index in countdown(7, 0):
    result.add char((bits shr (8 * index)) and 0xFF)

func longCodec(codec: string): string =
  ## The Matroska identifier for one of the four-character codes the rest of
  ## this library speaks — the inverse of `shortCodec`.
  ##
  ## A code with no Matroska equivalent is passed through, which produces a
  ## file naming a codec no player knows. That is better than refusing to write
  ## it: the caller knows what its samples are, and this is a muxer.
  case codec
  of "avc1", "avc3": "V_MPEG4/ISO/AVC"
  of "hvc1", "hev1": "V_MPEGH/ISO/HEVC"
  of "av01": "V_AV1"
  of "vp08": "V_VP8"
  of "vp09": "V_VP9"
  of "mp4v": "V_MPEG4/ISO/ASP"
  of "theo": "V_THEORA"
  of "mp4a": "A_AAC"
  of "Opus": "A_OPUS"
  of "vorb": "A_VORBIS"
  of "fLaC": "A_FLAC"
  of "lpcm": "A_PCM/INT/LIT"
  else: codec

type MatroskaWriter* = object
  ## An open sink and the cluster being built.
  ##
  ## Only one cluster is held, not the file: a cluster is bounded both by the
  ## span its block timestamps can express and by how far a player should have
  ## to read after a seek, so it stays small however long the recording.
  stream: Stream
  params: seq[TrackParams]
  scaleNs: int64
  blocks: string ## the current cluster's blocks, already encoded
  clusterAt: int64 ## the current cluster's timestamp, in segment units
  clusterOpen: bool
  nextTime: seq[int64] ## each track's next timestamp, in its own units
  shift: seq[int64] ## what the track's edit list asks be added, in its units
  cues: seq[tuple[time: int64; track: int; position: int64]]
  segmentSizeAt: int64 ## where the segment's length sits, for patching
  segmentBodyAt: int64 ## where its payload starts, which cues count from
  durationAt: int64 ## where the duration sits, for patching
  longest: int64 ## the furthest any track has reached, in segment units
  closed: bool
  ownsStream: bool

func segmentTicks(writer: MatroskaWriter; track: int; time: int64): int64 =
  ## A track's own timestamp, in the segment's units.
  ##
  ## Rounded rather than truncated: truncating would pull every timestamp
  ## earlier, and a stream whose frames all land a fraction early drifts
  ## against one whose do not.
  let scale = writer.params[track].timescale
  if scale <= 0: return 0
  let perSecond = 1_000_000_000'i64 div writer.scaleNs
  int64(round(float(time) * float(perSecond) / float(scale)))

proc newMatroskaWriter*(stream: Stream; tracks: openArray[TrackParams];
                        webm = false): MatroskaWriter {.contractual.} =
  ## Write the EBML header, the segment header and the track list, ready for
  ## samples.
  ##
  ## `webm` writes the restricted doc type, which a browser accepts and which
  ## says the codecs inside are royalty-free ones. Nothing here checks that
  ## they are: the caller chose the samples, and a muxer that second-guessed
  ## the claim would refuse files that are perfectly valid tomorrow.
  ##
  ## The segment's length and the duration are written wide and patched at
  ## `close`, so the stream must be one that can be seeked back into.
  require:
    tracks.len in 1 .. MaxWriterTracks
  body:
    for track in tracks:
      if track.kind == tkOther:
        raise newException(MovieError, "mkv: a track must be video or audio")
      if track.codec.len == 0:
        raise newException(MovieError, "mkv: a track needs a codec")
      if track.timescale notin 1 .. 1_000_000_000:
        raise newException(MovieError, "mkv: implausible timescale")
      if track.kind == tkVideo and
          (track.width notin 1 .. MaxDimension or
           track.height notin 1 .. MaxDimension):
        raise newException(MovieError, "mkv: a video track needs its size")
      if track.configKind == "esds":
        # Refused on the label the caller already gave, without reading the
        # bytes. Matroska wants the AudioSpecificConfig that sits inside an
        # `esds`, not the whole descriptor tree — and handed the tree, ffmpeg
        # reports "audio object type 0" and drops the track, which is a broken
        # file that no structural check catches.
        raise newException(MovieError,
          "mkv: A_AAC wants the AudioSpecificConfig, not the whole esds")
    if stream == nil:
      raise newException(IOError, "mkv: no stream to write to")

    result.stream = stream
    result.params = @tracks
    result.scaleNs = DefaultTimestampScaleNs
    result.nextTime = newSeq[int64](tracks.len)
    result.shift = newSeq[int64](tracks.len)
    for index, params in tracks:
      # Matroska has no edit list. What one says, though, is expressible as a
      # constant shift of the timestamps, and dropping it instead is what makes
      # a converted file play out of sync — the offset a reordered stream
      # begins with stops being cancelled.
      #
      # Only a leading empty edit and one trim are mapped, which is every edit
      # list a real file carries; anything past that is left alone rather than
      # approximated.
      for edit in params.edits:
        if edit.mediaTime < 0:
          let perSecond = 1_000_000_000'i64 div DefaultTimestampScaleNs
          result.shift[index] += edit.duration * int64(params.timescale) div
                                 perSecond
        else:
          result.shift[index] -= edit.mediaTime
          break

    var header = element(idEbmlVersion, uintPayload(1))
    header.add element(idEbmlReadVersion, uintPayload(1))
    header.add element(idEbmlMaxIdLength, uintPayload(4))
    header.add element(idEbmlMaxSizeLength, uintPayload(8))
    header.add element(idDocType, if webm: "webm" else: "matroska")
    header.add element(idDocTypeVersion, uintPayload(4))
    header.add element(idDocTypeReadVersion, uintPayload(2))
    stream.write(element(idEbml, header))

    # The segment's length is written as eight bytes so the real value fits
    # wherever it lands; a minimal encoding would have to grow to hold it and
    # move everything after it.
    stream.write(idBytes(idSegment))
    result.segmentSizeAt = int64(stream.getPosition())
    stream.write(sizeBytes(0, 8))
    result.segmentBodyAt = int64(stream.getPosition())

    var info = element(idTimestampScale, uintPayload(result.scaleNs))
    info.add element(idMuxingApp, "UniMovie")
    info.add element(idWritingApp, "UniMovie")
    # Written now and patched at close: the duration is not known until the
    # last sample is in, and a float is a fixed eight bytes either way.
    let durationOffset = info.len + idBytes(idDuration).len +
                         sizeBytes(8).len
    info.add element(idDuration, floatPayload(0.0))
    let infoElement = element(idInfo, info)
    result.durationAt = int64(stream.getPosition()) +
                        int64(infoElement.len - info.len) +
                        int64(durationOffset)
    stream.write(infoElement)

    var entries: string
    for index, params in tracks:
      var entry = element(idTrackNumber, uintPayload(int64(index + 1)))
      entry.add element(idTrackUid, uintPayload(int64(index + 1)))
      entry.add element(idTrackType,
        uintPayload(if params.kind == tkVideo: 1 else: 2))
      entry.add element(idCodecId, longCodec(params.codec))
      # Lacing off: every block this writes holds one frame, so a reader never
      # has to unpack one.
      entry.add element(idFlagLacing, uintPayload(0))
      if params.config.len > 0:
        entry.add element(idCodecPrivate, params.config)
      if params.kind == tkVideo:
        var video = element(idPixelWidth, uintPayload(int64(params.width)))
        video.add element(idPixelHeight, uintPayload(int64(params.height)))
        entry.add element(idVideo, video)
      else:
        var audio = element(idSamplingFrequency,
          floatPayload(float(max(params.sampleRate, 1))))
        audio.add element(idChannels, uintPayload(int64(max(params.channels, 1))))
        entry.add element(idAudio, audio)
      entries.add element(idTrackEntry, entry)
    stream.write(element(idTracks, entries))

proc newMatroskaWriter*(path: string; tracks: openArray[TrackParams];
                        webm = false): MatroskaWriter {.contractual.} =
  ## `newMatroskaWriter` over a file.
  require:
    path.len > 0
    tracks.len in 1 .. MaxWriterTracks
  body:
    let stream = openFileStream(path, fmWrite)
    if stream == nil:
      raise newException(IOError, "mkv: cannot write " & path)
    result = newMatroskaWriter(stream, tracks, webm)
    result.ownsStream = true

proc flushCluster*(writer: var MatroskaWriter) {.contractual.} =
  ## Write the cluster being built. A cluster holding nothing writes nothing.
  require:
    not writer.closed
  body:
    if not writer.clusterOpen or writer.blocks.len == 0:
      writer.clusterOpen = false
      writer.blocks.setLen(0)
      return
    var cluster = element(idClusterTimestamp, uintPayload(writer.clusterAt))
    cluster.add writer.blocks
    writer.stream.write(element(idCluster, cluster))
    writer.clusterOpen = false
    writer.blocks.setLen(0)

proc writeSample*(writer: var MatroskaWriter; track: int;
                  data: openArray[byte]; duration: int; keyframe = true;
                  compositionOffset = 0) {.contractual.} =
  ## Append one frame to `track`, `duration` units of that track's timescale
  ## long.
  ##
  ## **A block's timestamp is when the frame is shown, not when it is decoded**
  ## — the opposite of ISO base media, where `stts` gives decode times and
  ## `ctts` the distance to display. So `compositionOffset` is not dropped in
  ## the conversion: it is added in. Frames still go out in decode order, which
  ## is the order they arrive; only the timestamps carry the reordering.
  ##
  ## Writing decode times here instead produces a file that is well formed,
  ## reads back sample for sample, and shows a reordered stream's frames in the
  ## wrong order — which no structural check catches, only decoded pixels.
  ##
  ## A cluster is opened on the first frame and closed when a video keyframe
  ## arrives or when the span a block timestamp can express runs out.
  require:
    track >= 0
    duration >= 0
  body:
    if writer.closed: raise newException(MovieError, "mkv: writer is closed")
    if track >= writer.params.len:
      raise newException(MovieError, "mkv: track index past the file")
    if data.len == 0:
      raise newException(MovieError, "mkv: an empty frame has no meaning")

    let at = writer.segmentTicks(track,
      writer.nextTime[track] + int64(compositionOffset) + writer.shift[track])
    # A reordered stream puts a frame before its cluster's own timestamp, which
    # a signed offset holds; the break is on the distance either way, not on
    # the direction.
    if writer.clusterOpen and
        (abs(at - writer.clusterAt) > MaxClusterSpan or
         (keyframe and writer.params[track].kind == tkVideo)):
      writer.flushCluster()
    if not writer.clusterOpen:
      writer.clusterAt = at
      writer.clusterOpen = true
      if keyframe:
        writer.cues.add (at, track + 1,
          int64(writer.stream.getPosition()) - writer.segmentBodyAt)

    var block1 = sizeBytes(int64(track + 1))
    let offset = int16(at - writer.clusterAt)
    block1.add char((offset shr 8) and 0xFF)
    block1.add char(offset and 0xFF)
    block1.add char(if keyframe: 0x80 else: 0x00)
    let start = block1.len
    block1.setLen(start + data.len)
    copyMem(addr block1[start], unsafeAddr data[0], data.len)
    writer.blocks.add element(idSimpleBlock, block1)

    writer.nextTime[track] += int64(duration)
    let reached = writer.segmentTicks(track, writer.nextTime[track])
    if reached > writer.longest: writer.longest = reached

proc close*(writer: var MatroskaWriter) {.contractual.} =
  ## Flush the last cluster, write the cue index, and patch the segment's
  ## length and duration.
  require:
    not writer.closed
  body:
    writer.flushCluster()
    writer.closed = true

    if writer.cues.len > 0:
      var points: string
      for cue in writer.cues:
        var positions = element(idCueTrack, uintPayload(int64(cue.track)))
        positions.add element(idCueClusterPosition, uintPayload(cue.position))
        var point = element(idCueTime, uintPayload(cue.time))
        point.add element(idCueTrackPositions, positions)
        points.add element(idCuePoint, point)
      writer.stream.write(element(idCues, points))

    let endAt = int64(writer.stream.getPosition())
    writer.stream.setPosition(int(writer.durationAt))
    writer.stream.write(floatPayload(float(writer.longest)))
    writer.stream.setPosition(int(writer.segmentSizeAt))
    writer.stream.write(sizeBytes(endAt - writer.segmentBodyAt, 8))
    writer.stream.setPosition(int(endAt))
    if writer.ownsStream: writer.stream.close()

func trackCount*(writer: MatroskaWriter): int =
  ## How many tracks the writer was opened for.
  writer.params.len

func clusterCount*(writer: MatroskaWriter): int =
  ## How many cue points have been recorded — one per cluster that opened on a
  ## keyframe, which is what a player seeks to.
  writer.cues.len


