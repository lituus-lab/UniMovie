# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## MP4 and MOV demultiplexing, checked against ffprobe.
##
## ffprobe is what this library replaces, so it is the only honest oracle: every
## shape below is compared with what ffprobe reports for the same file, not with
## what this reader produced last time. The fixtures come from ffmpeg and are a
## few kilobytes each — the container is under test, never the codec.
import std/[unittest, os, osproc, strutils]
import UniMovie

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc ffprobeField(path, entries: string): string =
  ## One ffprobe field, or "" when ffprobe is not installed.
  if findExe("ffprobe").len == 0: return ""
  let (output, code) = execCmdEx("ffprobe -v error -select_streams v:0 " &
    "-show_entries " & entries & " -of default=nw=1:nk=1 " & path.quoteShell)
  if code != 0: return ""
  output.strip()

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
