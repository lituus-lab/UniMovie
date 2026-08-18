# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## One entry point: give it a file, get its shape back.
##
## The container is identified from the bytes, never from the extension — a
## `.avi` holding a Matroska stream is a real thing, and a caller should not
## have to guess. What this build does not read is named in the error rather
## than reported as a generic failure.

import contracts
import ./types
import ./isobmff
import ./matroska
import ./avi
import ./mpegts
import ./ogg

type Container* = enum
  ## What a file's leading bytes say it is.
  cUnknown = "unknown"
  cIsoBmff = "mp4"       ## MP4, MOV, M4V, 3GP — one format under four names
  cMatroska = "matroska" ## MKV and WebM
  cAvi = "avi"
  cMpegTs = "mpegts"     ## TS, M2TS, MTS — one format, three packet sizes
  cOgg = "ogg"           ## OGV

func sniff*(data: string): Container =
  ## Identify a container from its leading bytes, without reading its tables.
  ##
  ## `ftyp` is not at offset zero — it follows a four-byte box length — which is
  ## why this looks at byte 4 for ISOBMFF and byte 0 for the others. A transport
  ## stream has no magic at all and is recognised by the spacing of its sync
  ## bytes, so it is tried last.
  if data.len < 12: return cUnknown
  if data[0 .. 3] == "\x1A\x45\xDF\xA3": return cMatroska
  if data[0 .. 3] == "RIFF" and data[8 .. 11] == "AVI ": return cAvi
  if data[0 .. 3] == "OggS": return cOgg
  if data[4 .. 7] in ["ftyp", "moov", "mdat", "free", "skip", "wide"]:
    return cIsoBmff
  # A transport stream has no magic number: it is recognised by its rhythm, so
  # it is tried last, after every format that does have one.
  if isMpegTs(data): return cMpegTs
  cUnknown

func reads*(container: Container): bool =
  ## Whether this build demultiplexes that container.
  container != cUnknown

proc sniffFile*(path: string): Container {.contractual.} =
  ## Identify a file's container from its first bytes, reading only those.
  require:
    path.len > 0
  body:
    var handle: File
    if not handle.open(path):
      raise newException(IOError, "cannot open " & path)
    defer: handle.close()
    # Enough packets for a transport stream's rhythm to show: eight at the
    # largest packet size, plus room for the offset a .m2ts starts at.
    var head = newString(4096)
    let read = handle.readBuffer(addr head[0], 4096)
    head.setLen(read)
    sniff(head)

proc readMovie*(data: string): Movie {.contractual.} =
  ## Demultiplex whatever the bytes turn out to be.
  ##
  ## Nothing is required of the caller: the bytes come from a file, so an
  ## unrecognised or malformed one raises `MovieError` from the reader that
  ## claimed it.
  ensure:
    result.tracks.len > 0
  body:
    case sniff(data)
    of cIsoBmff: isobmff.readMovie(data)
    of cMatroska: readMatroska(data)
    of cAvi: readAvi(data)
    of cMpegTs: readMpegTs(data)
    of cOgg: readOgg(data)
    of cUnknown:
      raise newException(MovieError, "unrecognised video container")

proc codedSample*(data: string; trackIndex, sampleIndex: int): string
    {.contractual.} =
  ## The coded bytes of one sample, from whichever container the bytes turn out
  ## to be.
  ##
  ## This is the boundary: nothing here interprets them, and what comes back is
  ## the form that container stores. An H.264 track in an MP4 gives
  ## length-prefixed units and the same track in a transport stream gives start
  ## codes, because that is what each file holds — converting between them is
  ## the decoder backend's business, and doing it here would hide from a caller
  ## which form it has.
  ##
  ## The cost differs as sharply as the form. ISO base media reads an offset
  ## from a table; Matroska, AVI, Ogg and MPEG-TS index nothing, so reaching
  ## sample n means walking to it.
  require:
    trackIndex >= 0
    sampleIndex >= 0
  body:
    case sniff(data)
    of cIsoBmff: isobmff.codedSample(data, trackIndex, sampleIndex)
    of cMatroska: matroska.codedSample(data, trackIndex, sampleIndex)
    of cAvi: avi.codedSample(data, trackIndex, sampleIndex)
    of cMpegTs: mpegts.codedSample(data, trackIndex, sampleIndex)
    of cOgg: ogg.codedSample(data, trackIndex, sampleIndex)
    of cUnknown:
      raise newException(MovieError, "unrecognised video container")

proc codedSampleCount*(data: string; trackIndex: int): int {.contractual.} =
  ## How many coded samples a track holds, from whichever container the bytes
  ## turn out to be.
  ##
  ## `Track.sampleCount` reports 0 for the containers that declare no count;
  ## this walks and finds out, so a caller iterating a track has a bound in
  ## every case.
  require:
    trackIndex >= 0
  ensure:
    result >= 0
  body:
    case sniff(data)
    of cIsoBmff: isobmff.codedSampleCount(data, trackIndex)
    of cMatroska: matroska.codedSampleCount(data, trackIndex)
    of cAvi: avi.codedSampleCount(data, trackIndex)
    of cMpegTs: mpegts.codedSampleCount(data, trackIndex)
    of cOgg: ogg.codedSampleCount(data, trackIndex)
    of cUnknown:
      raise newException(MovieError, "unrecognised video container")

proc readMovieFile*(path: string): Movie {.contractual.} =
  ## `readMovie` over a file, read whole.
  ##
  ## Read whole rather than streamed: an MP4's tables may sit after the media,
  ## and a Matroska Segment may declare an unknown length, so neither can be
  ## demultiplexed from a forward-only stream. A path that cannot be opened
  ## raises `IOError`, which is what separates a missing file from a malformed
  ## one.
  require:
    path.len > 0
  ensure:
    result.tracks.len > 0
  body:
    # An ISO base media file is read box by box, so a recording of any size
    # costs its `moov` rather than its media. The others are read whole: their
    # parsers are bounded by lengths the file declares, and a truncated buffer
    # makes them stop at the damage rather than read what is there.
    if sniffFile(path) == cIsoBmff: readMovieHeaderFile(path)
    else: readMovie(readFile(path))


