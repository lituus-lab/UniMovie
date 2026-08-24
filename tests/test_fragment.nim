# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Writing a fragmented MP4, checked by decoding it with ffmpeg.
##
## The point of the format is that `moov` comes first and holds no sample
## table, so a file can be played before it is finished. What has to be proved
## is that the tables moved into the fragments still say the same thing: the
## same samples, in the same order, at the same times. Decoding to pixels and
## comparing with the source proves all three at once.
import std/[unittest, os, osproc, strutils]
import UniContainer/isobmff as boxlayer
import UniMovie

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc configOf(data: string; trackIndex: int; want: string): string =
  ## A track's codec configuration payload, so a remux carries the parameter
  ## set across without this suite parsing it.
  var bytes: seq[byte]
  for character in data: bytes.add byte(character)
  let moov = boxlayer.findBox(bytes, 0, bytes.len, ["moov"])
  var seen = 0
  for kind, body, bodyEnd in boxlayer.boxes(bytes, moov.body, moov.bodyEnd):
    if kind != "trak": continue
    if seen != trackIndex:
      inc seen
      continue
    let stsd = boxlayer.findBox(bytes, body, bodyEnd,
      ["mdia", "minf", "stbl", "stsd"])
    if stsd.body < 0: return ""
    for entry, entryBody, entryEnd in boxlayer.boxes(bytes, stsd.body + 8,
                                                     stsd.bodyEnd):
      # A video sample entry has 78 fixed bytes ahead of its configuration box
      # and an audio one 28.
      let fixed = if want == "avcC": 78 else: 28
      for inner, innerBody, innerEnd in boxlayer.boxes(bytes, entryBody + fixed,
                                                       entryEnd):
        if inner == want:
          result = newString(innerEnd - innerBody)
          for index in 0 ..< result.len:
            result[index] = char(bytes[innerBody + index])
          return
    return

proc paramsOf(source: string; movie: Movie): seq[TrackParams] =
  ## Writer parameters describing the tracks of an already-read movie, so a
  ## remux reproduces the source rather than a set of defaults invented here.
  for index, track in movie.tracks:
    let want = if track.kind == tkVideo: "avcC" else: "esds"
    result.add TrackParams(kind: track.kind, codec: track.codec,
      timescale: track.timescale, width: track.width, height: track.height,
      channels: 1, sampleRate: track.timescale, configKind: want,
      config: configOf(source, index, want), edits: editList(source, index))

proc bytesOf(data: string; track, index: int): seq[byte] =
  ## One coded sample as bytes, ready to hand to a writer.
  let sample = codedSample(data, track, index)
  result = newSeq[byte](sample.len)
  for position in 0 ..< sample.len: result[position] = byte(sample[position])

proc decodeToRaw(path, target: string): bool =
  ## Decode to raw pixels with ffmpeg. False when ffmpeg is absent.
  if findExe("ffmpeg").len == 0: return false
  execCmdEx("ffmpeg -v error -y -i " & path.quoteShell &
            " -f rawvideo -pix_fmt rgb24 " & target.quoteShell).exitCode == 0

proc hasBox(data, kind: string): bool =
  ## Whether a box of that kind sits at the top level. Top level only: a
  ## nested one of the same kind is a different claim, and one test here
  ## depends on telling the two apart.
  var bytes: seq[byte]
  for character in data: bytes.add byte(character)
  for outer, _, _ in boxlayer.boxes(bytes, 0, bytes.len):
    if outer == kind: return true

proc topLevelBoxes(data: string): seq[string] =
  ## The kinds of the top-level boxes, in file order — which is what says
  ## whether an initialisation segment precedes the fragments.
  var bytes: seq[byte]
  for character in data: bytes.add byte(character)
  for kind, _, _ in boxlayer.boxes(bytes, 0, bytes.len): result.add kind

suite "a fragmented file is written in the order the format asks for":
  setup:
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    let track = movie.tracks[index]
    let timing = sampleTiming(source, index)
    let target = getTempDir() /
      ("unimovie-frag-" & $getCurrentProcessId() & ".mp4")

  teardown:
    removeFile(target)

  test "moov comes before any media, and declares that fragments follow":
    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    for sample in 0 ..< track.sampleCount:
      writer.writeSample(0, bytesOf(source, index, sample),
        timing[sample].duration, sample in track.keyframes,
        timing[sample].compositionOffset)
    writer.close()
    let boxes = topLevelBoxes(readFile(target))
    check boxes[0] == "ftyp"
    check boxes[1] == "moov"
    check "moof" in boxes
    check boxes.find("moov") < boxes.find("moof")
    # `mvex` is what says the empty tables in `moov` mean "fragments follow"
    # rather than "this movie has nothing in it". It nests inside `moov`, so
    # it is reached by path — `hasBox` looks at the top level and would never
    # find it, which is how this check came to repeat the one above it.
    var bytes: seq[byte]
    for character in readFile(target): bytes.add byte(character)
    check boxlayer.findBox(bytes, 0, bytes.len, ["moov", "mvex"]).body >= 0

  test "one flush per keyframe gives one fragment per keyframe":
    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    for sample in 0 ..< track.sampleCount:
      if sample in track.keyframes and writer.pendingSamples(0) > 0:
        writer.flushFragment()
      writer.writeSample(0, bytesOf(source, index, sample),
        timing[sample].duration, sample in track.keyframes,
        timing[sample].compositionOffset)
    writer.close()
    check writer.fragmentCount == track.keyframes.len

  test "a flush with nothing buffered writes nothing":
    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    writer.flushFragment()
    check writer.fragmentCount == 0
    writer.writeSample(0, bytesOf(source, index, 0), timing[0].duration)
    writer.flushFragment()
    writer.flushFragment()
    check writer.fragmentCount == 1
    writer.close()

  test "ffprobe finds every sample across the fragments":
    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    for sample in 0 ..< track.sampleCount:
      if sample mod 2 == 0 and writer.pendingSamples(0) > 0:
        writer.flushFragment()
      writer.writeSample(0, bytesOf(source, index, sample),
        timing[sample].duration, sample in track.keyframes,
        timing[sample].compositionOffset)
    writer.close()
    if findExe("ffprobe").len == 0: skip()
    else:
      let (output, code) = execCmdEx("ffprobe -v error -count_packets " &
        "-select_streams v:0 -show_entries stream=nb_read_packets " &
        "-of csv=p=0 " & target.quoteShell)
      check code == 0
      check output.strip().splitLines()[0].strip() == $track.sampleCount

  test "the writer refuses what it cannot write":
    expect MovieError:
      discard newFragmentedMp4Writer(target, [TrackParams(kind: tkOther,
        codec: "avc1", timescale: 1000)])
    expect MovieError:
      discard newFragmentedMp4Writer(target, [TrackParams(kind: tkVideo,
        codec: "avc", timescale: 1000, width: 16, height: 16)])
    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    expect MovieError: writer.writeSample(9, [byte 1, 2], 100)
    expect MovieError: writer.writeSample(0, [], 100)
    writer.writeSample(0, bytesOf(source, index, 0), timing[0].duration)
    writer.close()
    # Closing twice is not tested: it is a precondition, as it is on the
    # whole-file writer, so it raises a defect in debug and is compiled away in
    # release — a test of it would assert different things in the two builds.

suite "a fragmented remux decodes to the same pixels":
  test "one video track, fragmented every other sample":
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    let track = movie.tracks[index]
    let timing = sampleTiming(source, index)
    let target = getTempDir() /
      ("unimovie-frag-pixels-" & $getCurrentProcessId() & ".mp4")
    defer: removeFile(target)

    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    for sample in 0 ..< track.sampleCount:
      if sample mod 2 == 0 and writer.pendingSamples(0) > 0:
        writer.flushFragment()
      writer.writeSample(0, bytesOf(source, index, sample),
        timing[sample].duration, sample in track.keyframes,
        timing[sample].compositionOffset)
    writer.close()

    let fromSource = getTempDir() / ("unimovie-src-" &
      $getCurrentProcessId() & ".raw")
    let fromFragments = getTempDir() / ("unimovie-frag-" &
      $getCurrentProcessId() & ".raw")
    defer:
      removeFile(fromSource)
      removeFile(fromFragments)
    if not decodeToRaw(Fixtures / "tiny.mp4", fromSource): skip()
    elif not decodeToRaw(target, fromFragments): skip()
    else:
      check readFile(fromSource) == readFile(fromFragments)

  test "two tracks interleaved, each fragment holding both":
    # Two tracks in one `moof` is where a sample offset can be wrong without
    # the file looking malformed: each `trun` counts from the `moof`, so the
    # second track's offset depends on the first track's length.
    let source = readFile(Fixtures / "av.mp4")
    let movie = readMovie(source)
    let video = movie.videoTrack
    let audio = movie.audioTrack
    check video >= 0 and audio >= 0
    let target = getTempDir() /
      ("unimovie-frag-av-" & $getCurrentProcessId() & ".mp4")
    defer: removeFile(target)

    var timings: seq[seq[tuple[duration, compositionOffset: int]]]
    for track in 0 ..< movie.tracks.len: timings.add sampleTiming(source, track)
    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    var audioAt = 0
    let perFrame = movie.tracks[audio].sampleCount div
                   movie.tracks[video].sampleCount
    for sample in 0 ..< movie.tracks[video].sampleCount:
      if sample > 0 and sample mod 2 == 0: writer.flushFragment()
      writer.writeSample(video, bytesOf(source, video, sample),
        timings[video][sample].duration,
        sample in movie.tracks[video].keyframes,
        timings[video][sample].compositionOffset)
      let want = min(audioAt + perFrame, movie.tracks[audio].sampleCount)
      while audioAt < want:
        writer.writeSample(audio, bytesOf(source, audio, audioAt),
          timings[audio][audioAt].duration)
        inc audioAt
    while audioAt < movie.tracks[audio].sampleCount:
      writer.writeSample(audio, bytesOf(source, audio, audioAt),
        timings[audio][audioAt].duration)
      inc audioAt
    writer.close()
    check writer.fragmentCount > 1

    let fromSource = getTempDir() / ("unimovie-av-src-" &
      $getCurrentProcessId() & ".raw")
    let fromFragments = getTempDir() / ("unimovie-av-frag-" &
      $getCurrentProcessId() & ".raw")
    defer:
      removeFile(fromSource)
      removeFile(fromFragments)
    if not decodeToRaw(Fixtures / "av.mp4", fromSource): skip()
    elif not decodeToRaw(target, fromFragments): skip()
    else:
      check readFile(fromSource) == readFile(fromFragments)

suite "a fragmented file is read back, whoever wrote it":
  test "ffmpeg's fragmented file gives the source's samples":
    # Written by ffmpeg, not by this library, so agreement is not two halves
    # of one mistake agreeing with each other.
    let source = readFile(Fixtures / "tiny.mp4")
    let fragmented = readFile(Fixtures / "fragmented.mp4")
    let index = readMovie(source).videoTrack
    let count = codedSampleCount(fragmented, 0)
    check count == codedSampleCount(source, index)
    for sample in 0 ..< count:
      check codedSample(fragmented, 0, sample) ==
            codedSample(source, index, sample)

  test "the timing survives the fragments":
    let source = readFile(Fixtures / "tiny.mp4")
    let fragmented = readFile(Fixtures / "fragmented.mp4")
    let index = readMovie(source).videoTrack
    check sampleTiming(fragmented, 0) == sampleTiming(source, index)

  test "a header sample count of zero means the fragments hold them":
    # `moov`'s tables are empty in such a file, which is what `mvex` says to
    # expect — the count is 0 for the same reason Matroska's is.
    let movie = readMovie(readFile(Fixtures / "fragmented.mp4"))
    check movie.tracks[0].sampleCount == 0
    check codedSampleCount(readFile(Fixtures / "fragmented.mp4"), 0) > 1

  test "what this library writes, it reads":
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    let track = movie.tracks[index]
    let timing = sampleTiming(source, index)
    let target = getTempDir() /
      ("unimovie-frag-roundtrip-" & $getCurrentProcessId() & ".mp4")
    defer: removeFile(target)
    var writer = newFragmentedMp4Writer(target, paramsOf(source, movie))
    for sample in 0 ..< track.sampleCount:
      if sample mod 3 == 0 and writer.pendingSamples(0) > 0:
        writer.flushFragment()
      writer.writeSample(0, bytesOf(source, index, sample),
        timing[sample].duration, sample in track.keyframes,
        timing[sample].compositionOffset)
    writer.close()
    let written = readFile(target)
    check codedSampleCount(written, 0) == track.sampleCount
    for sample in 0 ..< track.sampleCount:
      check codedSample(written, 0, sample) == codedSample(source, index, sample)
    check sampleTiming(written, 0) == timing

suite "a fragment whose runs do not each say where they start":
  # Neither this library nor ffmpeg writes two runs in one `traf`, and the
  # second of them may leave out its data offset — the format then says it
  # starts where the one before it ended. A file is assembled here to reach
  # that, because no encoder to hand produces one.

  proc be(value: int64; width: int): string =
    for index in countdown(width - 1, 0):
      result.add char((value shr (8 * index)) and 0xFF)

  proc box(kind, payload: string): string =
    be(int64(payload.len + 8), 4) & kind & payload

  proc fullBox(kind: string; version, flags: int; payload: string): string =
    box(kind, char(version) & be(int64(flags), 3) & payload)

  proc emptyTrack(): string =
    ## One `trak` with every table empty, which is what a fragmented file has.
    var tkhd = be(0, 8) & be(1, 4) & be(0, 4) & be(0, 4) & be(0, 8)
    tkhd.add be(0, 2) & be(0, 2) & be(0, 2) & be(0, 2)
    for value in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]:
      tkhd.add be(int64(value), 4)
    tkhd.add be(int64(16) shl 16, 4) & be(int64(16) shl 16, 4)
    let mdhd = be(0, 8) & be(1000, 4) & be(0, 4) & be(0x55C4, 2) & be(0, 2)
    let hdlr = be(0, 4) & "vide" & be(0, 12) & "\0"
    let dinf = box("dinf", fullBox("dref", 0, 0, be(1, 4) &
      box("url ", be(1, 4))))
    var entry = be(0, 6) & be(1, 2) & be(0, 16) & be(16, 2) & be(16, 2)
    entry.add be(0x0048_0000, 4) & be(0x0048_0000, 4) & be(0, 4) & be(1, 2)
    entry.add be(0, 32) & be(0x0018, 2) & be(0xFFFF, 2)
    let stsd = fullBox("stsd", 0, 0, be(1, 4) & box("avc1", entry))
    var stbl = stsd & fullBox("stts", 0, 0, be(0, 4))
    stbl.add fullBox("stsc", 0, 0, be(0, 4))
    stbl.add fullBox("stsz", 0, 0, be(0, 4) & be(0, 4))
    stbl.add fullBox("stco", 0, 0, be(0, 4))
    let minf = box("minf", fullBox("vmhd", 0, 0, be(0, 8)) & dinf &
                   box("stbl", stbl))
    let mdia = box("mdia", fullBox("mdhd", 0, 0, mdhd) &
                   fullBox("hdlr", 0, 0, hdlr) & minf)
    box("trak", fullBox("tkhd", 0, 0, tkhd) & mdia)

  proc twoRunFile(first, second: seq[string]): string =
    ## `ftyp`, a `moov` declaring fragments, then one `moof` whose single
    ## `traf` holds two runs — the first placed, the second not.
    var mvhd = be(0, 8) & be(1000, 4) & be(0, 4) & be(0x00010000, 4)
    mvhd.add be(0x0100, 2) & be(0, 10)
    for value in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]:
      mvhd.add be(int64(value), 4)
    mvhd.add be(0, 24) & be(2, 4)
    let trex = fullBox("trex", 0, 0,
      be(1, 4) & be(1, 4) & be(0, 4) & be(0, 4) & be(0, 4))
    let moov = box("moov", fullBox("mvhd", 0, 0, mvhd) & emptyTrack() &
                   box("mvex", trex))
    let ftyp = box("ftyp", "iso5\0\0\2\0iso5iso6mp42")

    proc run(frames: seq[string]; offset: int): string =
      # duration, size and flags per sample; the offset only on the first run.
      var flags = 0x0100 or 0x0200 or 0x0400
      if offset >= 0: flags = flags or 0x0001
      var payload = be(int64(frames.len), 4)
      if offset >= 0: payload.add be(int64(offset), 4)
      for frame in frames:
        payload.add be(100, 4) & be(int64(frame.len), 4) & be(0x0200_0000, 4)
      fullBox("trun", 0, flags, payload)

    # Built twice: the offset in the first run counts from the `moof`, whose
    # length is only known once the runs are in.
    var media = ""
    for frame in first: media.add frame
    for frame in second: media.add frame
    proc assemble(dataOffset: int): string =
      let traf = box("traf", fullBox("tfhd", 0, 0x020000, be(1, 4)) &
        fullBox("tfdt", 1, 0, be(0, 8)) & run(first, dataOffset) &
        run(second, -1))
      box("moof", fullBox("mfhd", 0, 0, be(1, 4)) & traf)
    let moofLength = assemble(0).len
    ftyp & moov & assemble(moofLength + 8) & box("mdat", media)

  test "the second run starts where the first one ended":
    let first = @["aaaa", "bbbbbb"]
    let second = @["cc", "dddddddd"]
    let data = twoRunFile(first, second)
    check codedSampleCount(data, 0) == 4
    for index, frame in first & second:
      check codedSample(data, 0, index) == frame

  test "a single placed run is unaffected":
    let only = @["one", "two", "three"]
    let data = twoRunFile(only, @[])
    check codedSampleCount(data, 0) == only.len
    for index, frame in only:
      check codedSample(data, 0, index) == frame
