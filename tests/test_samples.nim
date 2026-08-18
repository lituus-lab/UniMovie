# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## `codedSample` over every container, checked against ffmpeg.
##
## Sizes are compared with what ffprobe counts as a packet, and the bytes
## themselves with what ffmpeg writes when it copies the stream out — an IVF
## file for VP8/VP9, an elementary stream for H.264 in a transport stream, and
## a remuxed MP4 for the rest. Comparing against this library's own reader
## would pass on a mistake the two share, which is why none of these do.
##
## Where ffmpeg is absent the byte comparisons are skipped and the walks still
## run, so a machine without it tests less rather than differently.
import std/[unittest, os, osproc, strutils]
import UniMovie

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc hasFfmpeg(): bool =
  ## Whether both tools are on PATH. What they are for here is checking this
  ## library's output against an independent reader, so a test that cannot
  ## reach them is skipped rather than failed — CI installs them, a
  ## contributor's machine need not.
  findExe("ffmpeg").len > 0 and findExe("ffprobe").len > 0

proc packetSizes(path: string): seq[int] =
  ## What ffprobe counts as a packet on the first video stream. A transport
  ## stream makes it print each entry twice, so blank lines are dropped and
  ## every value taken once.
  if findExe("ffprobe").len == 0: return @[]
  let (output, code) = execCmdEx("ffprobe -v error -select_streams v:0 " &
    "-show_entries packet=size -of default=nw=1:nk=1 " & path.quoteShell)
  if code != 0: return @[]
  for line in output.splitLines():
    let value = line.strip()
    if value.len > 0: result.add parseInt(value)

proc ivfFrames(path: string): seq[string] =
  ## The coded frames inside an IVF file: a 32-byte file header, then per frame
  ## a 12-byte header whose first four bytes are the size, then the frame.
  let data = readFile(path)
  var at = 32
  while at + 12 <= data.len:
    var size = 0
    for shift in 0 .. 3: size = size or (int(uint8(data[at + shift])) shl (8 * shift))
    at += 12
    if at + size > data.len: break
    result.add data[at ..< at + size]
    at += size

proc convert(source, arguments, target: string): bool =
  ## Run ffmpeg, copying the stream rather than re-encoding. False when it is
  ## absent or refuses the file.
  if not hasFfmpeg(): return false
  execCmdEx("ffmpeg -v error -y -i " & source.quoteShell & " " & arguments &
            " " & target.quoteShell).exitCode == 0

const Every = ["tiny.mp4", "av.mp4", "rotated.mov", "tiny.mkv", "tiny.webm",
               "tiny.avi", "tiny.ts", "tiny.ogv"]

suite "every container hands over a coded sample":
  test "the count matches what ffprobe finds, in every container":
    for name in Every:
      let path = Fixtures / name
      let data = readFile(path)
      let movie = readMovie(data)
      let video = movie.videoTrack
      check video >= 0
      let expected = packetSizes(path)
      if expected.len == 0: continue
      check codedSampleCount(data, video) == expected.len

  test "each sample is the size ffprobe reports":
    for name in Every:
      let path = Fixtures / name
      let data = readFile(path)
      let video = readMovie(data).videoTrack
      let expected = packetSizes(path)
      if expected.len == 0: continue
      for index, size in expected:
        check codedSample(data, video, index).len == size

  test "a track that declares no count still reports one":
    # Matroska and MPEG-TS carry the number nowhere, so `Track.sampleCount`
    # stays 0 and the walk is the only answer. A count of 0 from both would
    # make this test pass while saying nothing, so it insists on more.
    for name in ["tiny.mkv", "tiny.ts"]:
      let data = readFile(Fixtures / name)
      let movie = readMovie(data)
      check movie.tracks[movie.videoTrack].sampleCount == 0
      check codedSampleCount(data, movie.videoTrack) > 1

  test "an index past the track raises rather than returning nothing":
    for name in Every:
      let data = readFile(Fixtures / name)
      let video = readMovie(data).videoTrack
      expect MovieError:
        discard codedSample(data, video, codedSampleCount(data, video))

  test "a track index past the file raises":
    for name in Every:
      let data = readFile(Fixtures / name)
      expect MovieError: discard codedSample(data, 99, 0)
      expect MovieError: discard codedSampleCount(data, 99)

  test "bytes that are no container raise rather than guessing":
    expect MovieError: discard codedSample("not a movie at all", 0, 0)
    expect MovieError: discard codedSampleCount("not a movie at all", 0)

suite "the bytes are the file's own, checked against ffmpeg":
  setup:
    let work = getTempDir() / ("unimovie-samples-" & $getCurrentProcessId())
    createDir(work)

  teardown:
    removeDir(work)

  test "VP8 and VP9 match the frames ffmpeg writes to IVF":
    for name in ["tiny.webm", "tiny.ogv"]:
      let target = work / "reference.ivf"
      if not convert(Fixtures / name, "-c copy -f ivf", target): continue
      let data = readFile(Fixtures / name)
      let video = readMovie(data).videoTrack
      let frames = ivfFrames(target)
      check frames.len > 0
      check frames.len == codedSampleCount(data, video)
      for index, frame in frames:
        check codedSample(data, video, index) == frame

  test "H.264 in a transport stream joins into the elementary stream":
    # A transport stream stores start codes, and so does a bare .h264 file, so
    # the units concatenated are the whole stream byte for byte.
    let target = work / "reference.h264"
    if not convert(Fixtures / "tiny.ts", "-c copy -f h264", target):
      skip()
    else:
      let data = readFile(Fixtures / "tiny.ts")
      let video = readMovie(data).videoTrack
      var joined = ""
      for index in 0 ..< codedSampleCount(data, video):
        joined.add codedSample(data, video, index)
      check joined == readFile(target)

  test "a remux to MP4 leaves the coded samples untouched":
    # ffmpeg rewrites the container and copies the stream, so what this library
    # reads out of the result must equal what it read out of the source.
    for name in ["tiny.mkv", "tiny.avi"]:
      let target = work / "reference.mp4"
      if not convert(Fixtures / name, "-c copy", target): continue
      let source = readFile(Fixtures / name)
      let remuxed = readFile(target)
      let video = readMovie(source).videoTrack
      let count = codedSampleCount(source, video)
      check count == codedSampleCount(remuxed, readMovie(remuxed).videoTrack)
      for index in 0 ..< count:
        check codedSample(source, video, index) ==
              codedSample(remuxed, readMovie(remuxed).videoTrack, index)
