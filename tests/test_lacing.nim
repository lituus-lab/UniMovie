# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Matroska's lacing, checked against blocks built by hand from the format.
##
## Lacing packs several frames into one block, so that a block header is not
## paid per frame on a stream whose frames are twenty bytes. Three schemes
## exist and a file may use any of them; ffmpeg writes none of the three, so a
## fixture from it cannot exercise the reader here.
##
## The blocks below are therefore assembled byte by byte from the
## specification, which is a stronger check than a fixture anyway: the frames
## that come out are compared with the ones that went in, and a size table
## misread by one byte fails immediately rather than producing a plausible
## frame of the wrong length.
import std/[unittest, os, osproc, strutils]
import UniMovie

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc vint(value: int; width = 0): string =
  ## An EBML length, marker bit stripped from the value.
  var found = max(width, 1)
  if width == 0:
    while found < 8 and value >= (1 shl (7 * found)) - 1: inc found
  for index in countdown(found - 1, 0):
    var byteValue = (value shr (8 * index)) and 0xFF
    if index == found - 1: byteValue = byteValue or (0x80 shr (found - 1))
    result.add char(byteValue)

proc element(id: string; payload: string): string =
  ## An EBML element: the id, the payload length, then the payload.
  id & vint(payload.len) & payload

proc uintOf(value: int): string =
  ## An EBML unsigned integer, in the fewest bytes that hold it. Zero is one
  ## zero byte rather than none, which is what a reader expects to find.
  if value == 0: return "\0"
  var width = 1
  while width < 8 and (value shr (8 * width)) != 0: inc width
  for index in countdown(width - 1, 0):
    result.add char((value shr (8 * index)) and 0xFF)

proc xiphSizes(sizes: openArray[int]): string =
  ## Each size but the last, as a run of 255s ending in a smaller byte.
  for index in 0 ..< sizes.len - 1:
    var left = sizes[index]
    while left >= 255:
      result.add char(255)
      left -= 255
    result.add char(left)

proc simpleBlock(frames: openArray[string]; lacing: int): string =
  ## One SimpleBlock on track 1, at timestamp 0, holding `frames`.
  ##
  ## `lacing` is 0 none, 1 Xiph, 2 fixed, 3 EBML — the two bits the format
  ## puts in the flags byte.
  var payload = vint(1) # track number
  payload.add "\0\0" # timestamp, relative to the cluster
  payload.add char(0x80 or (lacing shl 1)) # keyframe, plus the lacing bits
  if lacing != 0:
    payload.add char(frames.len - 1)
    case lacing
    of 1:
      var sizes: seq[int]
      for frame in frames: sizes.add frame.len
      payload.add xiphSizes(sizes)
    of 2: discard # fixed: every frame the same length, so nothing
    of 3:
      payload.add vint(frames[0].len)
      for index in 1 ..< frames.len - 1:
        # A signed difference, biased by half of what the width holds.
        let difference = frames[index].len - frames[index - 1].len
        payload.add vint(difference + ((1 shl 13) - 1), 2)
    else: discard
  for frame in frames: payload.add frame
  element("\xA3", payload)

proc matroskaWith(blocks: string): string =
  ## The smallest file the reader will accept, holding one cluster.
  var header = element("\x42\x86", uintOf(1))       # EBMLVersion
  header.add element("\x42\xF7", uintOf(1)) # EBMLReadVersion
  header.add element("\x42\xF2", uintOf(4)) # EBMLMaxIDLength
  header.add element("\x42\xF3", uintOf(8)) # EBMLMaxSizeLength
  header.add element("\x42\x82", "matroska") # DocType
  header.add element("\x42\x87", uintOf(4))
  header.add element("\x42\x85", uintOf(2))

  var entry = element("\xD7", uintOf(1)) # TrackNumber
  entry.add element("\x83", uintOf(1)) # TrackType: video
  entry.add element("\x86", "V_MPEG4/ISO/AVC") # CodecID
  var video = element("\xB0", uintOf(64)) # PixelWidth
  video.add element("\xBA", uintOf(48)) # PixelHeight
  entry.add element("\xE0", video)
  let tracks = element("\x16\x54\xAE\x6B", element("\xAE", entry))

  var info = element("\x2A\xD7\xB1", uintOf(1_000_000))       # TimestampScale
  let infoElement = element("\x15\x49\xA9\x66", info)

  var cluster = element("\xE7", uintOf(0)) # cluster timestamp
  cluster.add blocks
  let segment = element("\x18\x53\x80\x67",
    infoElement & tracks & element("\x1F\x43\xB6\x75", cluster))
  element("\x1A\x45\xDF\xA3", header) & segment

suite "several frames in one block, however they are packed":
  const Frames = @["one".repeat(4), "two".repeat(9), "three".repeat(3),
                   "four".repeat(7)]

  test "no lacing gives the block as one frame":
    let data = matroskaWith(simpleBlock(["a single frame"], 0))
    check codedSampleCount(data, 0) == 1
    check codedSample(data, 0, 0) == "a single frame"

  test "Xiph lacing gives every frame back":
    let data = matroskaWith(simpleBlock(Frames, 1))
    check codedSampleCount(data, 0) == Frames.len
    for index, frame in Frames:
      check codedSample(data, 0, index) == frame

  test "Xiph lacing survives a frame longer than 255 bytes":
    # The size of such a frame is written as a run of 255s, which is where an
    # off-by-one in the accumulator would show and nowhere else.
    let long = @["x".repeat(600), "y".repeat(12), "z".repeat(255)]
    let data = matroskaWith(simpleBlock(long, 1))
    check codedSampleCount(data, 0) == 3
    for index, frame in long:
      check codedSample(data, 0, index) == frame

  test "fixed lacing splits the block evenly":
    let even = @["1234", "5678", "9abc"]
    let data = matroskaWith(simpleBlock(even, 2))
    check codedSampleCount(data, 0) == 3
    for index, frame in even:
      check codedSample(data, 0, index) == frame

  test "EBML lacing gives every frame back":
    let data = matroskaWith(simpleBlock(Frames, 3))
    check codedSampleCount(data, 0) == Frames.len
    for index, frame in Frames:
      check codedSample(data, 0, index) == frame

  test "fixed lacing divides the bytes, not the frames that went in":
    # It states only a count, so the frames must already be one length. Given
    # three of 5, 3 and 1 bytes the total still divides by three, and what
    # comes back is three frames of three bytes — the block is well formed and
    # says something other than what was put in it.
    let uneven = @["12345", "678", "9"]
    let data = matroskaWith(simpleBlock(uneven, 2))
    check codedSampleCount(data, 0) == 3
    for index in 0 .. 2:
      check codedSample(data, 0, index).len == 3
    check codedSample(data, 0, 0) == "123"

  test "a fixed-laced block with a remainder yields nothing":
    # Ten bytes cannot be three equal frames, so the block is malformed and
    # the reader declines it rather than inventing a length.
    let remainder = @["12345", "678", "9x"]
    let data = matroskaWith(simpleBlock(remainder, 2))
    check codedSampleCount(data, 0) == 0

  test "the fixtures still read the same way":
    # The hand-built files above must not have changed what a real one does.
    #
    # Counted against ffprobe rather than asserted to be "more than one": a
    # reader that found two frames of ten would pass the looser check, and
    # dropping frames is precisely what a lacing bug does. Skipped where
    # ffprobe is absent, since then there is nothing to count against.
    for name in ["tiny.mkv", "tiny.webm"]:
      let path = Fixtures / name
      let mine = codedSampleCount(readFile(path), 0)
      check mine > 1
      if findExe("ffprobe").len > 0:
        let (output, code) = execCmdEx("ffprobe -v error -select_streams v:0 " &
          "-count_packets -show_entries stream=nb_read_packets " &
          "-of default=nw=1:nk=1 " & path.quoteShell)
        if code == 0 and output.strip.len > 0:
          check $mine == output.strip
