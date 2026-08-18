# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Ogg, as `.ogv` carries video in it.
##
## An Ogg file is a run of pages, each belonging to a logical stream named by a
## serial number, and pages of different streams interleave. A stream's first
## packet identifies its codec and carries its shape, which is all this reader
## needs: the pages after it are media.
##
## Nothing here decodes. The identification header is a fixed layout, read the
## way a container's header is read.

import contracts
import ./types

const
  MaxPages = 200_000
    ## A bound on how long a hostile file can hold this reader. Far more pages
    ## than any real recording of a length worth cataloguing.
  MaxStreams = 64

func beU16(data: string; at: int): int =
  ## Two big-endian bytes. Page headers are little-endian, but the codec
  ## identification headers inside them are big-endian — one of the format's
  ## sharper edges.
  (int(uint8(data[at])) shl 8) or int(uint8(data[at + 1]))

func beU24(data: string; at: int): int =
  ## Three big-endian bytes, which is how Theora stores a picture dimension.
  (int(uint8(data[at])) shl 16) or (int(uint8(data[at + 1])) shl 8) or
    int(uint8(data[at + 2]))

func beU32(data: string; at: int): int64 =
  ## Four big-endian bytes, for the frame rate in an identification header.
  result = 0
  for index in 0 .. 3:
    result = (result shl 8) or int64(uint8(data[at + index]))

func leU32(data: string; at: int): int64 =
  ## Four little-endian bytes: a page's serial number and sequence.
  result = 0
  for index in countdown(3, 0):
    result = (result shl 8) or int64(uint8(data[at + index]))

type Page = object
  ## One page's stream, whether it begins one, and where its packets are.
  serial: int64
  first: bool  ## the beginning-of-stream flag
  payloadAt, payloadLen: int
  packets: int ## how many packets end in this page
  size: int    ## the whole page, for stepping to the next

proc parsePage(data: string; at: int): Page =
  ## Split a page into its header and payload.
  ##
  ## The lacing table gives each segment's length; a segment shorter than 255
  ## ends a packet, which is how packet boundaries are found without any
  ## length field.
  result.serial = -1
  if at + 27 > data.len or data[at ..< at + 4] != "OggS": return
  let segments = int(uint8(data[at + 26]))
  let tableAt = at + 27
  if tableAt + segments > data.len: return
  var payloadLen = 0
  for index in 0 ..< segments:
    let lacing = int(uint8(data[tableAt + index]))
    payloadLen += lacing
    if lacing < 255: inc result.packets
  let payloadAt = tableAt + segments
  if payloadAt + payloadLen > data.len: return
  result.serial = leU32(data, at + 14)
  result.first = (int(uint8(data[at + 5])) and 0x02) != 0
  result.payloadAt = payloadAt
  result.payloadLen = payloadLen
  result.size = payloadAt + payloadLen - at

proc identify(data: string; at, size: int): tuple[kind: TrackKind;
    codec: string; width, height: int; fps: float; headers: int] =
  ## What a stream's first packet says it is, and how many header packets
  ## precede its media.
  ##
  ## The header count differs by codec — Theora has three, VP8 two — and it has
  ## to be subtracted before packets can be counted as frames. Only the video
  ## codecs carry a shape worth reporting; an audio stream is named and left at
  ## that, because `.ogv` is catalogued for its pictures.
  result.kind = tkOther
  result.headers = 1
  if size >= 42 and data[at ..< at + 7] == "\x80theora":
    # Theora: the frame size is in macroblocks, the picture size in pixels, and
    # they differ whenever the picture is not a multiple of sixteen.
    result.kind = tkVideo
    result.codec = "theo"
    result.headers = 3 # identification, comment, setup
    result.width = beU24(data, at + 14)
    result.height = beU24(data, at + 17)
    let numerator = beU32(data, at + 22)
    let denominator = beU32(data, at + 26)
    if denominator > 0: result.fps = float(numerator) / float(denominator)
  elif size >= 26 and data[at ..< at + 5] == "OVP80":
    result.kind = tkVideo
    result.codec = "vp08"
    result.headers = 2 # identification, comment
    result.width = beU16(data, at + 8)
    result.height = beU16(data, at + 10)
    let numerator = beU32(data, at + 18)
    let denominator = beU32(data, at + 22)
    if denominator > 0: result.fps = float(numerator) / float(denominator)
  elif size >= 7 and data[at ..< at + 7] == "\x01vorbis":
    result.kind = tkAudio
    result.codec = "vorb"
  elif size >= 8 and data[at ..< at + 8] == "OpusHead":
    result.kind = tkAudio
    result.codec = "Opus"
  elif size >= 5 and data[at ..< at + 5] == "\x7FFLAC":
    result.kind = tkAudio
    result.codec = "fLaC"
  if result.width notin 0 .. MaxDimension or
      result.height notin 0 .. MaxDimension:
    result.width = 0
    result.height = 0

proc readOgg*(data: string): Movie {.contractual.} =
  ## Demultiplex an Ogg file: every logical stream, its codec, and — for video —
  ## its picture size and playing time.
  ##
  ## The duration is the packet count over the frame rate rather than the last
  ## page's granule position: the granule encodes a keyframe and an offset in a
  ## codec-specific split, where counting packets means the same thing for every
  ## codec here and one frame per packet is what both Theora and VP8 write.
  ##
  ## Nothing is required of the caller: every byte comes from a file, so the
  ## checks are in the body and raise `MovieError`.
  ensure:
    result.tracks.len > 0
  body:
    if data.len < 27 or data[0 ..< 4] != "OggS":
      raise newException(MovieError, "ogg: no page at the start")
    result.format = "ogg"

    var serials: seq[int64]
    var found: seq[tuple[kind: TrackKind; codec: string; width, height: int;
                         fps: float; headers: int]]
    var packets: seq[int]

    var at = 0
    var pages = 0
    while at + 27 <= data.len and pages < MaxPages:
      let page = parsePage(data, at)
      if page.serial < 0 or page.size <= 0: break
      inc pages
      let index = serials.find(page.serial)
      if page.first and index < 0:
        if serials.len >= MaxStreams:
          raise newException(MovieError, "ogg: implausible stream count")
        serials.add page.serial
        found.add identify(data, page.payloadAt, page.payloadLen)
        packets.add 0
      elif index >= 0:
        packets[index] += page.packets
      at += page.size

    for index, stream in found:
      if stream.kind == tkOther and stream.codec.len == 0: continue
      var track = Track(id: int(serials[index] and 0x7FFF_FFFF),
                        kind: stream.kind, codec: stream.codec,
                        width: stream.width, height: stream.height,
                        timescale: 1000)
      if stream.kind == tkVideo and stream.fps > 0:
        # The identification packet is not counted — it lands on the page that
        # opened the stream — so only the headers after it are subtracted.
        let frames = max(packets[index] - (stream.headers - 1), 0)
        track.duration = int64(float(frames) / stream.fps * 1000.0)
        track.sampleCount = frames
      result.tracks.add track

    if result.tracks.len == 0:
      raise newException(MovieError, "ogg: no stream this build names")
    result.timescale = 1000
    for track in result.tracks:
      if track.kind == tkVideo and track.duration > result.duration:
        result.duration = track.duration

proc readOggFile*(path: string): Movie {.contractual.} =
  ## `readOgg` over a file. A path that cannot be opened raises `IOError`,
  ## which is what separates a missing file from a malformed one.
  require:
    path.len > 0
  body:
    readOgg(readFile(path))


