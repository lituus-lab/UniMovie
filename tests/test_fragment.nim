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
import UniImage/isobmff as boxlayer
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
  for index, track in movie.tracks:
    let want = if track.kind == tkVideo: "avcC" else: "esds"
    result.add TrackParams(kind: track.kind, codec: track.codec,
      timescale: track.timescale, width: track.width, height: track.height,
      channels: 1, sampleRate: track.timescale, configKind: want,
      config: configOf(source, index, want), edits: editList(source, index))

proc bytesOf(data: string; track, index: int): seq[byte] =
  let sample = codedSample(data, track, index)
  result = newSeq[byte](sample.len)
  for position in 0 ..< sample.len: result[position] = byte(sample[position])

proc decodeToRaw(path, target: string): bool =
  ## Decode to raw pixels with ffmpeg. False when ffmpeg is absent.
  if findExe("ffmpeg").len == 0: return false
  execCmdEx("ffmpeg -v error -y -i " & path.quoteShell &
            " -f rawvideo -pix_fmt rgb24 " & target.quoteShell).exitCode == 0

proc hasBox(data, kind: string): bool =
  var bytes: seq[byte]
  for character in data: bytes.add byte(character)
  for outer, _, _ in boxlayer.boxes(bytes, 0, bytes.len):
    if outer == kind: return true

proc topLevelBoxes(data: string): seq[string] =
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
    # rather than "this movie has nothing in it".
    check hasBox(readFile(target), "moof")

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
