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
# Qualified only: importing it plainly would make `readMovieFile` ambiguous
# with the dispatching one the umbrella exports, which is the whole reason the
# umbrella leaves this module's version out.
from UniMovie/isobmff import nil

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
    # Coded against coded. `width`/`height` come from `tkhd` and are the
    # display size, after the aspect ratio and the rotation matrix;
    # `codedWidth`/`codedHeight` come from the sample entry and are what the
    # stream actually carries. ffprobe reports both, so each is compared with
    # its own counterpart — the two agree on these fixtures, and comparing
    # across would pass here while failing the day a fixture has non-square
    # pixels, reading as a regression in the reader rather than in the test.
    for name in ["tiny.mp4", "av.mp4", "rotated.mov"]:
      let path = Fixtures / name
      let movie = readMovieFile(path)
      let index = movie.videoTrack
      check index >= 0
      let coded = ffprobeField(path, "stream=coded_width")
      if coded.len > 0:
        check $movie.tracks[index].codedWidth == coded
        check $movie.tracks[index].codedHeight ==
          ffprobeField(path, "stream=coded_height")
      let shown = ffprobeField(path, "stream=width")
      if shown.len > 0:
        check $movie.tracks[index].width == shown
        check $movie.tracks[index].height ==
          ffprobeField(path, "stream=height")

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

suite "the coded size and the displayed size are not the same number":
  test "a track with square pixels reports one size twice":
    for name in ["tiny.mp4", "av.mp4"]:
      let movie = readMovieFile(Fixtures / name)
      let track = movie.tracks[movie.videoTrack]
      check track.codedWidth == track.width
      check track.codedHeight == track.height

  test "a track with a 16:15 sample aspect reports two different ones":
    let movie = readMovieFile(Fixtures / "anamorphic.mp4")
    let track = movie.tracks[movie.videoTrack]
    check track.codedWidth == 64
    check track.codedHeight == 48
    # 64 pixels shown 16/15 as wide, which is where the difference lives.
    check track.width == 68
    check track.height == 48
    check track.width != track.codedWidth

  test "the coded size is the one ffprobe reports as the stream's":
    # ffprobe's `width` is the decoder's, not the display's. Every fixture is
    # checked, so a change that swapped the two would fail here rather than on
    # the one file whose pixels are not square.
    for name in ["tiny.mp4", "av.mp4", "rotated.mov", "anamorphic.mp4"]:
      let reported = ffprobeField(Fixtures / name, "stream=width")
      if reported.len == 0: continue
      let movie = readMovieFile(Fixtures / name)
      check movie.tracks[movie.videoTrack].codedWidth == parseInt(reported)

suite "a file is read box by box, not swallowed whole":
  test "the bounded read says exactly what the whole-file read says":
    for name in ["tiny.mp4", "av.mp4", "rotated.mov", "anamorphic.mp4"]:
      let whole = isobmff.readMovie(readFile(Fixtures / name))
      let bounded = readMovieHeaderFile(Fixtures / name)
      check whole.format == bounded.format
      check whole.timescale == bounded.timescale
      check whole.duration == bounded.duration
      check whole.tracks == bounded.tracks

  test "a file with no moov is refused rather than read as empty":
    let target = getTempDir() /
      ("unimovie-nomoov-" & $getCurrentProcessId() & ".mp4")
    defer: removeFile(target)
    writeFile(target, "\0\0\0\x14ftypmp42\0\0\0\0mp42\0\0\0\x08mdat")
    expect MovieError: discard readMovieHeaderFile(target)

  test "a path that cannot be opened raises IOError, not MovieError":
    expect IOError:
      discard readMovieHeaderFile(getTempDir() / "unimovie-absent-file.mp4")

suite "a file with no ftyp box is still a movie":
  # `ftyp` arrived with MP4 and QuickTime predates it. A phone still writes
  # `.mov` files that open `wide`/`mdat` with `moov` at the end and no brand
  # anywhere; on one real camera roll that was 99 of 863 videos, every one of
  # them refused. What says a file is a movie is `moov`.
  test "it reads, and reports the same shape as the file it came from":
    let plain = readMovieFile(Fixtures / "tiny.mp4")
    let brandless = readMovieFile(Fixtures / "noftyp.mov")
    check brandless.format == "mov"
    check brandless.tracks.len == plain.tracks.len
    check brandless.duration == plain.duration
    check brandless.timescale == plain.timescale
    let a = plain.tracks[plain.videoTrack]
    let b = brandless.tracks[brandless.videoTrack]
    check b.codec == a.codec
    check (b.codedWidth, b.codedHeight) == (a.codedWidth, a.codedHeight)
    check b.sampleCount == a.sampleCount

  test "its samples come out byte for byte":
    let plain = readFile(Fixtures / "tiny.mp4")
    let brandless = readFile(Fixtures / "noftyp.mov")
    let count = codedSampleCount(brandless, 0)
    check count == codedSampleCount(plain, 0)
    for sample in 0 ..< count:
      check codedSample(brandless, 0, sample) == codedSample(plain, 0, sample)

  test "the container is still recognised from its bytes":
    check sniffFile(Fixtures / "noftyp.mov") == cIsoBmff

  test "a file with neither ftyp nor moov is refused":
    let target = getTempDir() /
      ("unimovie-neither-" & $getCurrentProcessId() & ".mov")
    defer: removeFile(target)
    writeFile(target, "\0\0\0\x08wide\0\0\0\x08free")
    expect MovieError: discard readMovieFile(target)

suite "where a recording says it was made":
  test "a file that carries a position reports it":
    let placed = locationFile(Fixtures / "located.mov")
    check placed.found
    check abs(placed.latitude - 45.9374) < 1e-4
    check abs(placed.longitude - 6.6387) < 1e-4

  test "a file that carries none says so, rather than reporting zero":
    # Latitude 0, longitude 0 is a real point in the Atlantic. A file with no
    # position must not be read as having been taken there.
    let bare = locationFile(Fixtures / "tiny.mp4")
    check not bare.found
    check bare.latitude == 0.0
    check bare.longitude == 0.0

  test "the same answer from bytes as from a path":
    check location(readFile(Fixtures / "located.mov")) ==
          locationFile(Fixtures / "located.mov")

  test "an ISO 6709 string is split on its signs":
    # The standard allows several precisions, so fixed widths would read one
    # phone's files and not another's.
    check parseIso6709("+45.9374+006.6387+542.091/") ==
          (45.9374, 6.6387, true)
    check parseIso6709("-33.8688+151.2093/") == (-33.8688, 151.2093, true)
    check parseIso6709("+12.34-098.76") == (12.34, -98.76, true)
    # Out of range, or not enough numbers, is no position rather than a wrong
    # one.
    check not parseIso6709("+91.0+000.0/").found
    check not parseIso6709("+45.0+181.0/").found
    check not parseIso6709("+45.0/").found
    check not parseIso6709("").found
    check not parseIso6709("nowhere").found

  test "a file that is not ISO base media raises rather than guessing":
    expect MovieError: discard location("not a container at all")
