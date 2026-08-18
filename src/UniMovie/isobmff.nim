# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## ISO base media file format: MP4, MOV, M4V, and everything else built on it.
##
## A file is a tree of boxes. `moov` describes the presentation, one `trak` per
## track, and `mdat` holds the coded samples with nothing marking where one ends
## — the `stbl` tables inside each track are the only map, which is why a reader
## that cannot parse them cannot find a single frame.
##
## Nothing here decodes. A track reports the four-character code its samples are
## in — `avc1`, `hvc1`, `av01` — and the coded bytes of any one sample; turning
## those into pixels belongs to a backend the application registers.
##
## Every offset, count and length comes from a table an arbitrary file controls,
## so each is checked against the file's real length before it is used.
##
## The box walk itself — `boxes` and `findBox` — comes from `UniImage`, which
## reads the same structure for HEIF and for the Exif item inside an MP4. One
## box reader in the family, not two.
##
## The submodule is imported rather than the umbrella: `import UniImage` would
## pull every image codec into a demuxer that decodes nothing — 278 KB over 63
## translation units against 74 KB over 5, measured.

import contracts
import std/strutils
import UniImage/exif/isobmff
import ./types

type Reader = object
  ## The whole file in memory. `moov` may follow `mdat`, and the sample tables
  ## are scattered through the tree, so there is no forward-only reading of an
  ## MP4 — a demuxer needs random access or it needs the file.
  data: string

template bytes(reader: Reader): untyped =
  ## The file as the bytes `UniImage`'s box walk takes. A template rather than a
  ## proc: `toOpenArrayByte` cannot be returned, only passed on.
  reader.data.toOpenArrayByte(0, reader.data.high)

func beU16(reader: Reader; offset: int): int =
  ## Two big-endian bytes. ISOBMFF is big-endian throughout.
  (int(uint8(reader.data[offset])) shl 8) or int(uint8(reader.data[offset + 1]))

func beU32(reader: Reader; offset: int): int64 =
  ## Four big-endian bytes, widened so a size near 2^32 stays positive and
  ## cannot slip past a `> 0` check on its way to being used as a length.
  result = 0
  for index in 0 .. 3:
    result = (result shl 8) or int64(uint8(reader.data[offset + index]))

func beU64(reader: Reader; offset: int): int64 =
  ## Eight big-endian bytes: a `co64` offset, a version-1 duration, or the size
  ## of a box whose 32-bit size field was the escape value 1.
  result = 0
  for index in 0 .. 7:
    result = (result shl 8) or int64(uint8(reader.data[offset + index]))

func beI32(reader: Reader; offset: int): int32 =
  ## Four big-endian bytes as signed, for the transformation matrix, whose
  ## entries are negative in half the rotations.
  cast[int32](uint32(reader.beU32(offset) and 0xFFFF_FFFF))

func fourCC(reader: Reader; offset: int): string =
  ## The four-character code at `offset`, as written. Not upper-cased and not
  ## trimmed: `avc1` and `AVC1` are different codes, and a trailing space is
  ## part of a brand like `mp4 `.
  reader.data[offset ..< offset + 4]

func rotationOf(a, b, c, d: int32): Rotation =
  ## The display rotation a track's transformation matrix encodes.
  ##
  ## The matrix maps a source point to a display point as `x' = a*x + c*y` and
  ## `y' = b*x + d*y`, with y increasing downwards. So `a=0, b=-1, c=1, d=0`
  ## sends the source's rightward axis to the display's upward one, which is a
  ## quarter turn anticlockwise — `rot270` in the clockwise terms this library
  ## reports, and what ffprobe calls `rotation=90`.
  ##
  ## The entries are 16.16 fixed point, so 1.0 is 0x00010000. Only the four
  ## right-angle rotations are recognised; a matrix doing anything else — a
  ## shear, a flip, an arbitrary angle — reports `rot0`, because reporting a
  ## wrong right angle would be worse than reporting none.
  const one = 0x0001_0000'i32
  if a == one and b == 0 and c == 0 and d == one: rot0
  elif a == 0 and b == one and c == -one and d == 0: rot90
  elif a == -one and b == 0 and c == 0 and d == -one: rot180
  elif a == 0 and b == -one and c == one and d == 0: rot270
  else: rot0


proc parseTkhd(reader: Reader; body, bodyEnd: int; track: var Track) =
  ## Track header: the identifier, the display rotation, and — for video — the
  ## display dimensions.
  ##
  ## Version 1 widens the two timestamps and the duration from 32 bits to 64,
  ## which pushes everything after them twelve bytes along; the matrix and the
  ## dimensions are found by counting from the start rather than by a constant.
  if body + 4 > bodyEnd: return
  let version = int(uint8(reader.data[body]))
  let wide = if version == 1: 12 else: 0
  let idAt = body + 4 + (if version == 1: 16 else: 8)
  if idAt + 4 > bodyEnd: return
  track.id = int(reader.beU32(idAt))
  # version/flags, times, id, reserved, duration, 8 reserved, layer, group,
  # volume, reserved — then the nine matrix entries.
  let matrixAt = body + 4 + 8 + wide + 4 + 4 + 4 + 8 + 2 + 2 + 2 + 2
  if matrixAt + 36 + 8 > bodyEnd: return
  track.rotation = rotationOf(reader.beI32(matrixAt), reader.beI32(matrixAt + 4),
                              reader.beI32(matrixAt + 12), reader.beI32(
                                  matrixAt + 16))
  # Width and height are 16.16 fixed point. The fractional part is always zero
  # in practice, and a sub-pixel display size is not something to report.
  let sizeAt = matrixAt + 36
  let width = int(reader.beU32(sizeAt) shr 16)
  let height = int(reader.beU32(sizeAt + 4) shr 16)
  if width in 1 .. MaxDimension and height in 1 .. MaxDimension:
    track.width = width
    track.height = height

proc parseMdhd(reader: Reader; body, bodyEnd: int; track: var Track) =
  ## Media header: the timescale every duration in this track is counted in,
  ## and the track's own duration.
  if body + 4 > bodyEnd: return
  let version = int(uint8(reader.data[body]))
  if version == 1:
    if body + 4 + 16 + 4 + 8 > bodyEnd: return
    track.timescale = int(reader.beU32(body + 4 + 16))
    track.duration = reader.beU64(body + 4 + 20)
  else:
    if body + 4 + 8 + 4 + 4 > bodyEnd: return
    track.timescale = int(reader.beU32(body + 4 + 8))
    track.duration = reader.beU32(body + 4 + 12)
  if track.timescale <= 0: track.timescale = 0
  if track.duration < 0: track.duration = 0

proc parseHdlr(reader: Reader; body, bodyEnd: int): TrackKind =
  ## Handler type: what the track carries. `vide` and `soun` are the two that
  ## matter; `hint`, `sbtl`, `text`, `tmcd` and the rest are reported as
  ## `tkOther` so a caller still sees the whole file.
  if body + 12 > bodyEnd: return tkOther
  case reader.fourCC(body + 8)
  of "vide": tkVideo
  of "soun": tkAudio
  else: tkOther

proc parseStsd(reader: Reader; body, bodyEnd: int): string =
  ## The first sample entry's four-character code — the codec, as the container
  ## names it. Not resolved to a friendlier name: `avc1` and `avc3` differ in
  ## where their parameter sets live, and flattening both to "h264" would lose
  ## what a backend needs to know.
  if body + 8 > bodyEnd: return ""
  for kind, entryBody, entryEnd in boxes(reader.bytes, body + 8, bodyEnd):
    return kind
  ""

proc parseStss(reader: Reader; body, bodyEnd: int; sampleCount: int): seq[int] =
  ## The sync sample table: which samples a player may start at.
  ##
  ## Indices are one-based in the file and zero-based here. An entry outside the
  ## sample table is dropped rather than raising: a keyframe index that is
  ## slightly wrong should cost the caller that entry, not the whole file.
  if body + 8 > bodyEnd: return
  let count = int(reader.beU32(body + 4))
  if count < 0 or count > MaxSamples: raise newException(MovieError,
    "mp4: implausible sync sample count")
  if body + 8 + count * 4 > bodyEnd: raise newException(MovieError,
    "mp4: sync sample table is truncated")
  for index in 0 ..< count:
    let sample = int(reader.beU32(body + 8 + index * 4)) - 1
    if sample >= 0 and sample < sampleCount: result.add sample

proc parseTrak(reader: Reader; body, bodyEnd: int): Track =
  ## One track: its header, its media header, what it carries, its codec and
  ## its sample count, plus the keyframe index when the file has one.
  let tkhd = findBox(reader.bytes, body, bodyEnd, ["tkhd"])
  if tkhd.body >= 0: reader.parseTkhd(tkhd.body, tkhd.bodyEnd, result)
  let mdhd = findBox(reader.bytes, body, bodyEnd, ["mdia", "mdhd"])
  if mdhd.body >= 0: reader.parseMdhd(mdhd.body, mdhd.bodyEnd, result)
  let hdlr = findBox(reader.bytes, body, bodyEnd, ["mdia", "hdlr"])
  if hdlr.body >= 0: result.kind = reader.parseHdlr(hdlr.body, hdlr.bodyEnd)
  let stbl = findBox(reader.bytes, body, bodyEnd, ["mdia", "minf", "stbl"])
  if stbl.body < 0: return
  let stsd = findBox(reader.bytes, stbl.body, stbl.bodyEnd, ["stsd"])
  if stsd.body >= 0: result.codec = reader.parseStsd(stsd.body, stsd.bodyEnd)
  let stsz = findBox(reader.bytes, stbl.body, stbl.bodyEnd, ["stsz"])
  if stsz.body >= 0 and stsz.body + 12 <= stsz.bodyEnd:
    let count = int(reader.beU32(stsz.body + 8))
    if count < 0 or count > MaxSamples:
      raise newException(MovieError, "mp4: implausible sample count")
    result.sampleCount = count
  let stss = findBox(reader.bytes, stbl.body, stbl.bodyEnd, ["stss"])
  if stss.body >= 0:
    result.keyframes = reader.parseStss(stss.body, stss.bodyEnd,
        result.sampleCount)
  elif result.sampleCount > 0:
    # No sync table means every sample is a sync sample. Said explicitly rather
    # than left empty, so a caller need not know the convention to seek.
    for index in 0 ..< result.sampleCount: result.keyframes.add index


proc sampleTable(reader: Reader; stbl, stblEnd: int; fileLen: int):
    tuple[offsets, sizes: seq[int]] =
  ## Where every coded sample of a track begins and how long it is.
  ##
  ## The file says this in three pieces that only mean something together:
  ## `stsz` gives each sample's length, `stco` (or `co64`) the byte offset of
  ## each *chunk*, and `stsc` how many samples each run of chunks holds. A
  ## sample's offset is its chunk's offset plus the lengths of the samples
  ## before it in that chunk.
  var sizes: seq[int]
  var chunkOffsets: seq[int]
  var runs: seq[tuple[firstChunk, perChunk: int]]

  for kind, body, bodyEnd in boxes(reader.bytes, stbl, stblEnd):
    case kind
    of "stsz":
      if body + 12 > bodyEnd: continue
      let uniform = int(reader.beU32(body + 4))
      let count = int(reader.beU32(body + 8))
      if count < 0 or count > MaxSamples:
        raise newException(MovieError, "mp4: implausible sample count")
      sizes = newSeq[int](count)
      if uniform != 0:
        # One length for every sample, so the table is absent entirely.
        for index in 0 ..< count: sizes[index] = uniform
      else:
        if body + 12 + count * 4 > bodyEnd:
          raise newException(MovieError, "mp4: sample size table is truncated")
        for index in 0 ..< count:
          sizes[index] = int(reader.beU32(body + 12 + index * 4))
    of "stco", "co64":
      if body + 8 > bodyEnd: continue
      let count = int(reader.beU32(body + 4))
      if count < 0 or count > MaxSamples:
        raise newException(MovieError, "mp4: implausible chunk count")
      let width = if kind == "stco": 4 else: 8
      if body + 8 + count * width > bodyEnd:
        raise newException(MovieError, "mp4: chunk offset table is truncated")
      chunkOffsets = newSeq[int](count)
      for index in 0 ..< count:
        chunkOffsets[index] =
          if width == 4: int(reader.beU32(body + 8 + index * 4))
          else: int(reader.beU64(body + 8 + index * 8))
    of "stsc":
      if body + 8 > bodyEnd: continue
      let count = int(reader.beU32(body + 4))
      if count < 0 or count > MaxSamples:
        raise newException(MovieError, "mp4: implausible stsc count")
      if body + 8 + count * 12 > bodyEnd:
        raise newException(MovieError, "mp4: stsc is truncated")
      for index in 0 ..< count:
        runs.add (int(reader.beU32(body + 8 + index * 12)),
                  int(reader.beU32(body + 8 + index * 12 + 4)))
    else: discard

  if sizes.len == 0 or chunkOffsets.len == 0 or runs.len == 0:
    raise newException(MovieError, "mp4: sample table is incomplete")

  result.sizes = sizes
  result.offsets = newSeq[int](sizes.len)
  var sample = 0
  var run = 0
  for chunk in 0 ..< chunkOffsets.len:
    while run + 1 < runs.len and runs[run + 1].firstChunk <= chunk + 1: inc run
    var offset = chunkOffsets[chunk]
    for _ in 0 ..< runs[run].perChunk:
      if sample >= sizes.len: break
      if offset < 0 or sizes[sample] < 0 or offset + sizes[sample] > fileLen:
        raise newException(MovieError, "mp4: a sample lies outside the file")
      result.offsets[sample] = offset
      offset += sizes[sample]
      inc sample
  if sample < sizes.len:
    raise newException(MovieError, "mp4: the chunk table leaves samples unplaced")

proc readMovie*(data: string): Movie {.contractual.} =
  ## Demultiplex an ISOBMFF file: its brand, its timescale and duration, and
  ## every track with its codec, shape, rotation and keyframe index.
  ##
  ## Reads structure only. No sample is touched, so the cost is the size of the
  ## `moov` box rather than of the file.
  ##
  ## Nothing is required of the caller: every byte here comes from a file, so
  ## the checks belong in the body and raise `MovieError`. The postcondition is
  ## the guarantee that matters — a movie that comes back has at least one
  ## track, so a caller never has to test for an empty one.
  ensure:
    result.tracks.len > 0
  body:
    if data.len < 8: raise newException(MovieError, "mp4: too short to be a file")
    let reader = Reader(data: data)
    let ftyp = findBox(reader.bytes, 0, data.len, ["ftyp"])
    if ftyp.body < 0 or ftyp.body + 4 > ftyp.bodyEnd:
      raise newException(MovieError, "mp4: no ftyp box")
    # The major brand names the format. `qt  ` is QuickTime, which shares the
    # box structure and differs only in which brands and codecs appear.
    let brand = reader.fourCC(ftyp.body)
    result.format = if brand == "qt  ": "mov" else: brand.strip(chars = {' '})

    let moov = findBox(reader.bytes, 0, data.len, ["moov"])
    if moov.body < 0: raise newException(MovieError, "mp4: no moov box")
    let mvhd = findBox(reader.bytes, moov.body, moov.bodyEnd, ["mvhd"])
    if mvhd.body >= 0 and mvhd.body + 4 <= mvhd.bodyEnd:
      let version = int(uint8(data[mvhd.body]))
      if version == 1 and mvhd.body + 4 + 16 + 4 + 8 <= mvhd.bodyEnd:
        result.timescale = int(reader.beU32(mvhd.body + 4 + 16))
        result.duration = reader.beU64(mvhd.body + 4 + 20)
      elif mvhd.body + 4 + 8 + 4 + 4 <= mvhd.bodyEnd:
        result.timescale = int(reader.beU32(mvhd.body + 4 + 8))
        result.duration = reader.beU32(mvhd.body + 4 + 12)
    if result.duration < 0: result.duration = 0

    for kind, body, bodyEnd in boxes(reader.bytes, moov.body, moov.bodyEnd):
      if kind != "trak": continue
      if result.tracks.len >= MaxTracks:
        raise newException(MovieError, "mp4: implausible track count")
      result.tracks.add reader.parseTrak(body, bodyEnd)
    if result.tracks.len == 0:
      raise newException(MovieError, "mp4: no track")

proc codedSample*(data: string; trackIndex, sampleIndex: int): string
    {.contractual.} =
  ## The coded bytes of one sample, exactly as the file holds them.
  ##
  ## This is what a decoder backend is handed. Nothing here interprets them: an
  ## `avc1` sample comes back in its length-prefixed form, an `av01` one as its
  ## OBUs, because converting between them is the backend's business.
  require:
    trackIndex >= 0
    sampleIndex >= 0
  body:
    let reader = Reader(data: data)
    let moov = findBox(reader.bytes, 0, data.len, ["moov"])
    if moov.body < 0: raise newException(MovieError, "mp4: no moov box")
    var seen = 0
    for kind, body, bodyEnd in boxes(reader.bytes, moov.body, moov.bodyEnd):
      if kind != "trak": continue
      if seen != trackIndex:
        inc seen
        continue
      let stbl = findBox(reader.bytes, body, bodyEnd, ["mdia", "minf", "stbl"])
      if stbl.body < 0: raise newException(MovieError, "mp4: track has no stbl")
      let table = reader.sampleTable(stbl.body, stbl.bodyEnd, data.len)
      if sampleIndex >= table.sizes.len:
        raise newException(MovieError, "mp4: sample index past the track")
      let at = table.offsets[sampleIndex]
      return data[at ..< at + table.sizes[sampleIndex]]
    raise newException(MovieError, "mp4: track index past the file")

proc sampleTiming*(data: string; trackIndex: int):
    seq[tuple[duration, compositionOffset: int]] {.contractual.} =
  ## Per-sample decode duration and composition offset, in the track's own
  ## timescale.
  ##
  ## Read on demand rather than carried on `Track`, because `readMovie` costs
  ## the size of `moov` and this costs one entry per sample — an hour of video
  ## is a hundred thousand of them, which a caller asking only for a file's
  ## shape should not pay for.
  ##
  ## The composition offset is how far a sample's display time sits from its
  ## decode time. It is non-zero only where the encoder reordered, and a file
  ## with no `ctts` box reports every offset as 0 — which is what "not
  ## reordered" means, so there is no unknown case here.
  ##
  ## Anything that rewrites a track needs both: writing samples back in decode
  ## order without their offsets puts a reordered stream out of sequence.
  require:
    trackIndex >= 0
  body:
    let reader = Reader(data: data)
    let moov = findBox(reader.bytes, 0, data.len, ["moov"])
    if moov.body < 0: raise newException(MovieError, "mp4: no moov box")
    var seen = 0
    for kind, body, bodyEnd in boxes(reader.bytes, moov.body, moov.bodyEnd):
      if kind != "trak": continue
      if seen != trackIndex:
        inc seen
        continue
      let stbl = findBox(reader.bytes, body, bodyEnd,
        ["mdia", "minf", "stbl"])
      if stbl.body < 0: raise newException(MovieError, "mp4: track has no stbl")

      let stts = findBox(reader.bytes, stbl.body, stbl.bodyEnd, ["stts"])
      if stts.body >= 0 and stts.body + 8 <= stts.bodyEnd:
        let count = int(reader.beU32(stts.body + 4))
        if count < 0 or count > MaxSamples:
          raise newException(MovieError, "mp4: implausible stts count")
        if stts.body + 8 + count * 8 > stts.bodyEnd:
          raise newException(MovieError, "mp4: stts is truncated")
        for index in 0 ..< count:
          let run = int(reader.beU32(stts.body + 8 + index * 8))
          let delta = int(reader.beU32(stts.body + 8 + index * 8 + 4))
          if run < 0 or result.len + run > MaxSamples:
            raise newException(MovieError, "mp4: stts describes too many samples")
          for _ in 0 ..< run: result.add (delta, 0)

      let ctts = findBox(reader.bytes, stbl.body, stbl.bodyEnd, ["ctts"])
      if ctts.body >= 0 and ctts.body + 8 <= ctts.bodyEnd:
        # Version 1 stores the offset signed, which is how a stream whose first
        # frame displays before it decodes expresses itself.
        let signed = int(uint8(data[ctts.body])) == 1
        let count = int(reader.beU32(ctts.body + 4))
        if count < 0 or count > MaxSamples:
          raise newException(MovieError, "mp4: implausible ctts count")
        if ctts.body + 8 + count * 8 > ctts.bodyEnd:
          raise newException(MovieError, "mp4: ctts is truncated")
        var at = 0
        for index in 0 ..< count:
          let run = int(reader.beU32(ctts.body + 8 + index * 8))
          let raw = reader.beU32(ctts.body + 8 + index * 8 + 4)
          let offset = if signed: int(cast[int32](uint32(raw and 0xFFFF_FFFF)))
                       else: int(raw)
          for _ in 0 ..< run:
            if at >= result.len: break
            result[at].compositionOffset = offset
            inc at
      return
    raise newException(MovieError, "mp4: track index past the file")

proc readMovieFile*(path: string): Movie {.contractual.} =
  ## `readMovie` over a file, read whole: `moov` may sit after `mdat`, so the
  ## tables cannot be found from a forward-only stream. A path that cannot be
  ## opened raises `IOError`, which is what separates a missing file from a
  ## malformed one.
  require:
    path.len > 0
  body:
    readMovie(readFile(path))




