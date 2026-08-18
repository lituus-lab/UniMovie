# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## MP4 and MOV demultiplexing, checked against ffprobe.
##
## ffprobe is what this library replaces, so it is the only honest oracle: every
## shape below is compared with what ffprobe reports for the same file, not with
## what this reader produced last time. The fixtures come from ffmpeg and are a
## few kilobytes each — the container is under test, never the codec.
import std/[unittest, os, osproc, strutils, tables]
import UniMovie

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc ffprobeField(path, entries: string): string =
  ## One ffprobe field, or "" when ffprobe is not installed.
  if findExe("ffprobe").len == 0: return ""
  let (output, code) = execCmdEx("ffprobe -v error -select_streams v:0 " &
    "-show_entries " & entries & " -of default=nw=1:nk=1 " & path.quoteShell)
  if code != 0: return ""
  # A transport stream makes ffprobe print the entry more than once, so take
  # the first non-empty line rather than the whole output.
  for line in output.splitLines():
    let value = line.strip()
    if value.len > 0: return value
  ""

suite "mp4 shape":
  test "a video-only file reports its track":
    let movie = readMovieFile(Fixtures / "tiny.mp4")
    check movie.tracks.len == 1
    let track = movie.tracks[0]
    check track.kind == tkVideo
    check track.codec == "avc1"
    check (track.width, track.height) == (64, 48)
    check track.sampleCount == 10 # 10 fps for one second
    check abs(movie.durationSeconds - 1.0) < 0.05

  test "dimensions agree with ffprobe":
    for name in ["tiny.mp4", "av.mp4", "rotated.mov"]:
      let path = Fixtures / name
      let movie = readMovieFile(path)
      let index = movie.videoTrack
      check index >= 0
      let width = ffprobeField(path, "stream=width")
      if width.len > 0:
        check $movie.tracks[index].width == width
        check $movie.tracks[index].height == ffprobeField(path, "stream=height")

  test "an audio track is found beside the video one":
    let movie = readMovieFile(Fixtures / "av.mp4")
    check movie.tracks.len == 2
    check movie.videoTrack == 0
    check movie.audioTrack == 1
    check movie.tracks[1].kind == tkAudio
    # AAC in MP4 is `mp4a`; the container's code is reported, not a friendlier
    # name, because that is what a backend is registered under.
    check movie.tracks[1].codec == "mp4a"

  test "a track with no video reports -1 rather than raising":
    let movie = readMovieFile(Fixtures / "tiny.mp4")
    check movie.audioTrack == -1

suite "rotation":
  test "a rotated track reports the quarter turn, clockwise":
    # ffprobe calls this rotation=90 counting anticlockwise; the same matrix is
    # rot270 clockwise. The two agree, and the sign is the trap.
    let movie = readMovieFile(Fixtures / "rotated.mov")
    check movie.tracks[movie.videoTrack].rotation == rot270

  test "an unrotated track reports rot0":
    let movie = readMovieFile(Fixtures / "tiny.mp4")
    check movie.tracks[movie.videoTrack].rotation == rot0

suite "keyframes":
  test "a file with a sync table reports only its sync samples":
    # Encoded with -g 5 over ten frames, so not every sample is a keyframe.
    let movie = readMovieFile(Fixtures / "tiny.mp4")
    let track = movie.tracks[movie.videoTrack]
    check track.keyframes.len > 0
    check track.keyframes.len < track.sampleCount
    check track.keyframes[0] == 0
    for index in 1 ..< track.keyframes.len:
      check track.keyframes[index] > track.keyframes[index - 1]
      check track.keyframes[index] < track.sampleCount

  test "a track with no sync table calls every sample a keyframe":
    # Audio has no stss: every frame is independently decodable, and the
    # convention is that its absence means exactly that.
    let movie = readMovieFile(Fixtures / "av.mp4")
    let track = movie.tracks[movie.audioTrack]
    check track.keyframes.len == track.sampleCount

suite "coded samples":
  test "a sample comes back at the length its table declares":
    let data = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(data)
    var total = 0
    for index in 0 ..< movie.tracks[0].sampleCount:
      let sample = codedSample(data, 0, index)
      check sample.len > 0
      total += sample.len
    # Every coded sample together is most of the file; the rest is moov.
    check total < data.len
    check total > data.len div 2

  test "an index past the track is refused":
    let data = readFile(Fixtures / "tiny.mp4")
    expect MovieError:
      discard codedSample(data, 0, 10_000)
    expect MovieError:
      discard codedSample(data, 99, 0)

suite "malformed input is reported, not fatal":
  test "bytes that are not a container at all":
    expect MovieError:
      discard readMovie("not a movie, not even close")

  test "an empty string":
    expect MovieError:
      discard readMovie("")

  test "every prefix of a real file":
    # A truncated download must raise rather than read past its own buffer.
    let data = readFile(Fixtures / "tiny.mp4")
    var step = 1
    while step < data.len:
      try:
        discard readMovie(data[0 ..< step])
      except MovieError, IOError, ValueError:
        discard
      step += 97

  test "a file whose ftyp is intact but whose moov is gone":
    let data = readFile(Fixtures / "tiny.mp4")
    let at = data.find("moov")
    check at > 0
    var damaged = data
    damaged[at .. at + 3] = "xxxx"
    expect MovieError:
      discard readMovie(damaged)

suite "what the contracts promise":
  test "a movie with no declared timescale reports zero, in either build":
    # A header that omits the timescale is a fact about the file, not a
    # caller's mistake, so it must not be a precondition: one would raise in
    # debug and divide by zero in release.
    var data = readFile(Fixtures / "tiny.mp4")
    let at = data.find("mvhd")
    check at > 0
    data[at .. at + 3] = "xxxx"
    let movie = readMovie(data)
    check movie.timescale == 0
    check movie.durationSeconds == 0.0
    check movie.tracks[0].durationSeconds > 0.0 # the track still declares one

  test "a track index is either -1 or safe to use":
    for name in ["tiny.mp4", "av.mp4", "rotated.mov"]:
      let movie = readMovieFile(Fixtures / name)
      for index in [movie.videoTrack, movie.audioTrack]:
        check index == -1 or index in 0 ..< movie.tracks.len

  test "a movie that comes back always has a track":
    # The postcondition, stated from the outside: readMovie raises rather than
    # returning an empty presentation.
    for name in ["tiny.mp4", "av.mp4", "rotated.mov"]:
      check readMovieFile(Fixtures / name).tracks.len > 0

suite "the edit list, which a faithful remux cannot drop":
  test "the fixtures' edit lists are the ones ffmpeg reports":
    # Each of these cancels something. The video ones cancel the constant
    # composition offset a reordered stream begins with; av.mp4's audio one
    # trims the 1024 samples of encoder priming an AAC stream starts with.
    let cases = {"av.mp4": @[(44100'i64, 4096'i64), (44100'i64, 1024'i64)],
                 "tiny.mp4": @[(1000'i64, 2048'i64)],
                 "rotated.mov": @[(10240'i64, 4096'i64)]}.toTable
    for name, expected in cases:
      let data = readFile(Fixtures / name)
      for track, want in expected:
        let edits = editList(data, track)
        check edits.len == 1
        check edits[0].duration == want[0]
        check edits[0].mediaTime == want[1]

  test "a track with no edit list reports none, not a failure":
    # Written here rather than found: none of the fixtures lacks one.
    let plain = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(plain)
    let index = movie.videoTrack
    let timing = sampleTiming(plain, index)
    let target = getTempDir() /
      ("unimovie-noedit-" & $getCurrentProcessId() & ".mp4")
    defer: removeFile(target)
    var writer = newMp4Writer(target, [TrackParams(kind: tkVideo,
      codec: movie.tracks[index].codec, timescale: movie.tracks[
          index].timescale,
      width: movie.tracks[index].width, height: movie.tracks[index].height)])
    for sample in 0 ..< movie.tracks[index].sampleCount:
      let bytes = codedSample(plain, index, sample)
      var payload = newSeq[byte](bytes.len)
      for at in 0 ..< bytes.len: payload[at] = byte(bytes[at])
      writer.writeSample(0, payload, timing[sample].duration)
    writer.close()
    check editList(readFile(target), 0).len == 0

  test "a track index past the file raises":
    let data = readFile(Fixtures / "tiny.mp4")
    expect MovieError: discard editList(data, 99)

  test "what is written comes back":
    let plain = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(plain)
    let index = movie.videoTrack
    let timing = sampleTiming(plain, index)
    let target = getTempDir() /
      ("unimovie-roundedit-" & $getCurrentProcessId() & ".mp4")
    defer: removeFile(target)
    let wanted = @[Edit(duration: 250, mediaTime: -1),
                   Edit(duration: 750, mediaTime: 2048)]
    var writer = newMp4Writer(target, [TrackParams(kind: tkVideo,
      codec: movie.tracks[index].codec, timescale: movie.tracks[
          index].timescale,
      width: movie.tracks[index].width, height: movie.tracks[index].height,
      edits: wanted)])
    for sample in 0 ..< movie.tracks[index].sampleCount:
      let bytes = codedSample(plain, index, sample)
      var payload = newSeq[byte](bytes.len)
      for at in 0 ..< bytes.len: payload[at] = byte(bytes[at])
      writer.writeSample(0, payload, timing[sample].duration)
    writer.close()
    check editList(readFile(target), 0) == wanted
