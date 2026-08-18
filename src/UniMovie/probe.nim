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

type Container* = enum
  ## What a file's leading bytes say it is.
  cUnknown = "unknown"
  cIsoBmff = "mp4"       ## MP4, MOV, M4V, 3GP — one format under four names
  cMatroska = "matroska" ## MKV and WebM
  cAvi = "avi"

func sniff*(data: string): Container =
  ## Identify a container from its leading bytes, without reading its tables.
  ##
  ## `ftyp` is not at offset zero — it follows a four-byte box length — which is
  ## why this looks at byte 4 for ISOBMFF and byte 0 for the other two.
  if data.len < 12: return cUnknown
  if data[0 .. 3] == "\x1A\x45\xDF\xA3": return cMatroska
  if data[0 .. 3] == "RIFF" and data[8 .. 11] == "AVI ": return cAvi
  if data[4 .. 7] in ["ftyp", "moov", "mdat", "free", "skip", "wide"]:
    return cIsoBmff
  cUnknown

func reads*(container: Container): bool =
  ## Whether this build demultiplexes that container.
  container != cUnknown

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
    readMovie(readFile(path))

proc sniffFile*(path: string): Container {.contractual.} =
  ## Identify a file's container from its first bytes, reading only those.
  require:
    path.len > 0
  body:
    var handle: File
    if not handle.open(path):
      raise newException(IOError, "cannot open " & path)
    defer: handle.close()
    var head = newString(16)
    let read = handle.readBuffer(addr head[0], 16)
    head.setLen(read)
    sniff(head)


