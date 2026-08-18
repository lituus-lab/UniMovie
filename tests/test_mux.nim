# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Writing MP4, checked by reading the result back with something else.
##
## The strongest check here is a remux: every coded sample of a real file is
## read out, written back through the muxer, and the result decoded by ffmpeg.
## Identical pixels mean the sample framing, the timing tables and the codec
## configuration all survived — none of which a structural check alone proves.
import std/[unittest, os, osproc, strutils]
import UniImage/isobmff as boxlayer
import UniMovie

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc avcConfig(data: string): string =
  ## The `avcC` payload out of a file's sample entry, so a remux can carry the
  ## parameter set across without this suite parsing it.
  var bytes: seq[byte]
  for character in data: bytes.add byte(character)
  let stsd = boxlayer.findBox(bytes, 0, bytes.len,
    ["moov", "trak", "mdia", "minf", "stbl", "stsd"])
  if stsd.body < 0: return ""
  for kind, body, bodyEnd in boxlayer.boxes(bytes, stsd.body + 8, stsd.bodyEnd):
    # The configuration box follows the sample entry's 78 fixed bytes.
    for inner, innerBody, innerEnd in boxlayer.boxes(bytes, body + 78, bodyEnd):
      if inner == "avcC":
        result = newString(innerEnd - innerBody)
        for index in 0 ..< result.len:
          result[index] = char(bytes[innerBody + index])
        return

proc decodeToRaw(path, target: string): bool =
  ## Decode `path` to raw pixels with ffmpeg. False when ffmpeg is absent.
  if findExe("ffmpeg").len == 0: return false
  execCmdEx("ffmpeg -v error -y -i " & path.quoteShell &
            " -f rawvideo -pix_fmt rgb24 " & target.quoteShell).exitCode == 0

proc sampleBytes(data: string; track, index: int): seq[byte] =
  let sample = codedSample(data, track, index)
  result = newSeq[byte](sample.len)
  for position in 0 ..< sample.len: result[position] = byte(sample[position])

suite "a written file reads back":
  test "one video track, sample for sample":
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    let track = movie.tracks[index]
    let timing = sampleTiming(source, index)
    let target = getTempDir() / "unimovie-mux-basic.mp4"
    defer: removeFile(target)

    var writer = newMp4Writer(target, [TrackParams(kind: tkVideo,
      codec: track.codec, timescale: track.timescale, width: track.width,
      height: track.height, configKind: "avcC", config: avcConfig(source))])
    check writer.trackCount == 1
    for sample in 0 ..< track.sampleCount:
      writer.writeSample(0, sampleBytes(source, index, sample),
        timing[sample].duration, sample in track.keyframes,
        timing[sample].compositionOffset)
    check writer.sampleCount(0) == track.sampleCount
    writer.close()

    let back = readMovieFile(target)
    check back.tracks.len == 1
    let written = back.tracks[0]
    check written.kind == tkVideo
    check written.codec == track.codec
    check (written.width, written.height) == (track.width, track.height)
    check written.sampleCount == track.sampleCount
    check written.keyframes == track.keyframes
    check abs(back.durationSeconds - movie.durationSeconds) < 0.05

  test "every coded sample comes back byte for byte":
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    let timing = sampleTiming(source, index)
    let target = getTempDir() / "unimovie-mux-bytes.mp4"
    defer: removeFile(target)

    var writer = newMp4Writer(target, [TrackParams(kind: tkVideo,
      codec: movie.tracks[index].codec,
      timescale: movie.tracks[index].timescale,
      width: movie.tracks[index].width, height: movie.tracks[index].height,
      configKind: "avcC", config: avcConfig(source))])
    for sample in 0 ..< movie.tracks[index].sampleCount:
      writer.writeSample(0, sampleBytes(source, index, sample),
        timing[sample].duration, true, timing[sample].compositionOffset)
    writer.close()

    let written = readFile(target)
    for sample in 0 ..< movie.tracks[index].sampleCount:
      check codedSample(written, 0, sample) == codedSample(source, index, sample)

suite "a remuxed file decodes to the same pixels":
  test "ffmpeg decodes the remux identically to the source":
    # The fixture has B-frames, so its samples are stored out of display order.
    # Writing them back without their composition offsets would decode to the
    # right pictures in the wrong sequence, which only a pixel check catches.
    if findExe("ffmpeg").len == 0:
      skip()
    else:
      let source = readFile(Fixtures / "tiny.mp4")
      let movie = readMovie(source)
      let index = movie.videoTrack
      let track = movie.tracks[index]
      let timing = sampleTiming(source, index)
      let target = getTempDir() / "unimovie-mux-remux.mp4"
      let mine = getTempDir() / "unimovie-mux-mine.raw"
      let theirs = getTempDir() / "unimovie-mux-theirs.raw"
      defer:
        removeFile(target)
        removeFile(mine)
        removeFile(theirs)

      var writer = newMp4Writer(target, [TrackParams(kind: tkVideo,
        codec: track.codec, timescale: track.timescale, width: track.width,
        height: track.height, configKind: "avcC", config: avcConfig(source))])
      for sample in 0 ..< track.sampleCount:
        writer.writeSample(0, sampleBytes(source, index, sample),
          timing[sample].duration, sample in track.keyframes,
          timing[sample].compositionOffset)
      writer.close()

      check decodeToRaw(target, mine)
      check decodeToRaw(Fixtures / "tiny.mp4", theirs)
      check readFile(mine) == readFile(theirs)

suite "composition offsets":
  test "the fixture really is reordered, or the pixel check proves nothing":
    let source = readFile(Fixtures / "tiny.mp4")
    let timing = sampleTiming(source, readMovie(source).videoTrack)
    var reordered = false
    for entry in timing:
      if entry.compositionOffset != 0: reordered = true; break
    check reordered

  test "a stream with no ctts reports every offset as zero":
    # Audio is never reordered, so its absence of a ctts box is the normal case.
    let source = readFile(Fixtures / "av.mp4")
    let movie = readMovie(source)
    for entry in sampleTiming(source, movie.audioTrack):
      check entry.compositionOffset == 0
      check entry.duration > 0

suite "the writer refuses what it cannot write":
  test "a track that is neither video nor audio":
    expect MovieError:
      discard newMp4Writer(getTempDir() / "unimovie-bad.mp4",
        [TrackParams(kind: tkOther, codec: "text", timescale: 1000)])

  test "a codec code that is not four characters":
    expect MovieError:
      discard newMp4Writer(getTempDir() / "unimovie-bad.mp4",
        [TrackParams(kind: tkVideo, codec: "h264", timescale: 1000,
                     width: 0, height: 0)])

  test "a video track with no dimensions":
    expect MovieError:
      discard newMp4Writer(getTempDir() / "unimovie-bad.mp4",
        [TrackParams(kind: tkVideo, codec: "avc1", timescale: 1000)])

  test "a sample for a track that does not exist":
    let target = getTempDir() / "unimovie-bad-track.mp4"
    var writer = newMp4Writer(target, [TrackParams(kind: tkAudio,
      codec: "mp4a", timescale: 44100, channels: 2, sampleRate: 44100)])
    defer: removeFile(target)
    expect MovieError:
      writer.writeSample(5, [byte 1, 2, 3], 1024)
    expect MovieError:
      writer.writeSample(0, [], 1024)
    writer.writeSample(0, [byte 1, 2, 3], 1024)
    writer.close()

  test "closing with nothing written":
    let target = getTempDir() / "unimovie-empty.mp4"
    var writer = newMp4Writer(target, [TrackParams(kind: tkAudio,
      codec: "mp4a", timescale: 44100, channels: 2, sampleRate: 44100)])
    defer: removeFile(target)
    expect MovieError:
      writer.close()

proc editListLines(path: string): seq[string] =
  ## What ffmpeg's own demuxer reads out of a file's edit lists, one line per
  ## entry. Empty when ffmpeg is absent — the values are then unchecked rather
  ## than assumed.
  if findExe("ffprobe").len == 0: return @[]
  let (output, _) = execCmdEx("ffprobe -v debug " & path.quoteShell & " 2>&1")
  for line in output.splitLines():
    if "edit list" in line and "media time:" in line:
      result.add line[line.find("edit list") .. ^1].strip()

proc hasBox(data, kind: string): bool =
  ## Whether a box of that kind appears anywhere in the file's `moov`.
  var bytes: seq[byte]
  for character in data: bytes.add byte(character)
  let moov = boxlayer.findBox(bytes, 0, bytes.len, ["moov"])
  if moov.body < 0: return false
  for outer, body, bodyEnd in boxlayer.boxes(bytes, moov.body, moov.bodyEnd):
    if outer != "trak": continue
    for inner, _, _ in boxlayer.boxes(bytes, body, bodyEnd):
      if inner == kind: return true

suite "an edit list, when the caller asks for one":
  # The fixture is reordered, so its first sample is displayed 2048 units after
  # it is decoded. That offset is what an edit list is most often written to
  # cancel, which makes it the honest thing to demonstrate against.
  setup:
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    let track = movie.tracks[index]
    let timing = sampleTiming(source, index)
    let config = avcConfig(source)
    # Named for this process: two builds of this suite run at once collide
    # over a fixed name, and the failure that causes looks like a muxer bug.
    let target = getTempDir() / ("unimovie-elst-" & $getCurrentProcessId() & ".mp4")

  teardown:
    removeFile(target)

  proc remux(target: string; track: Track; source: string; index: int;
             timing: seq[tuple[duration, compositionOffset: int]];
             config: string; edits: seq[Edit]) =
    var writer = newMp4Writer(target, [TrackParams(kind: tkVideo,
      codec: track.codec, timescale: track.timescale, width: track.width,
      height: track.height, configKind: "avcC", config: config, edits: edits)])
    for sample in 0 ..< track.sampleCount:
      writer.writeSample(0, sampleBytes(source, index, sample),
        timing[sample].duration, sample in track.keyframes,
        timing[sample].compositionOffset)
    writer.close()

  test "no edits writes no edts box at all":
    remux(target, track, source, index, timing, config, @[])
    check not hasBox(readFile(target), "edts")
    check editListLines(target).len == 0

  test "an empty edit holds the track back, and ffmpeg reads it back":
    remux(target, track, source, index, timing, config,
          @[Edit(duration: 500, mediaTime: -1), Edit(duration: 0,
              mediaTime: 0)])
    check hasBox(readFile(target), "edts")
    let lines = editListLines(target)
    if lines.len == 0: skip()
    else:
      check lines.len == 2
      # ffmpeg reports the duration in the track's own timescale, so the 500
      # milliseconds asked for come back as half of 10240.
      check "media time: -1" in lines[0]
      check "duration: 5120" in lines[0]
      check "media time: 0" in lines[1]

  test "a zero duration means the rest of the track":
    remux(target, track, source, index, timing, config,
          @[Edit(duration: 0, mediaTime: 2048)])
    let lines = editListLines(target)
    if lines.len == 0: skip()
    else:
      check lines.len == 1
      check "media time: 2048" in lines[0]
      # One second of media, in the track's timescale rather than the movie's.
      check "duration: " & $track.timescale in lines[0]

  test "the samples are untouched by the edit list":
    remux(target, track, source, index, timing, config,
          @[Edit(duration: 0, mediaTime: 2048)])
    let written = readFile(target)
    let writtenTrack = readMovie(written).videoTrack
    check codedSampleCount(written, writtenTrack) == track.sampleCount
    for sample in 0 ..< track.sampleCount:
      check codedSample(written, writtenTrack, sample) ==
            codedSample(source, index, sample)

  test "an edit the format cannot hold is refused":
    expect MovieError:
      discard newMp4Writer(target, [TrackParams(kind: tkVideo, codec: "avc1",
        timescale: 1000, width: 16, height: 16,
        edits: @[Edit(duration: -1, mediaTime: 0)])])
    expect MovieError:
      discard newMp4Writer(target, [TrackParams(kind: tkVideo, codec: "avc1",
        timescale: 1000, width: 16, height: 16,
        edits: @[Edit(duration: 0, mediaTime: -2)])])
    expect MovieError:
      discard newMp4Writer(target, [TrackParams(kind: tkVideo, codec: "avc1",
        timescale: 1000, width: 16, height: 16,
        edits: @[Edit(duration: 1'i64 shl 33, mediaTime: 0)])])
