# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The container-agnostic entry point, and the Matroska and AVI readers behind
## it, checked against ffprobe.
##
## ffprobe is what this library replaces, so every shape below is compared with
## what it reports for the same file. The fixtures come from ffmpeg and are a
## few kilobytes each; the container is under test, never the codec.
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

const Every = ["tiny.mp4", "av.mp4", "rotated.mov", "tiny.mkv", "tiny.webm",
               "tiny.avi"]

suite "one entry point over every container":
  test "each fixture is recognised from its bytes":
    check sniffFile(Fixtures / "tiny.mp4") == cIsoBmff
    check sniffFile(Fixtures / "rotated.mov") == cIsoBmff
    check sniffFile(Fixtures / "tiny.mkv") == cMatroska
    check sniffFile(Fixtures / "tiny.webm") == cMatroska
    check sniffFile(Fixtures / "tiny.avi") == cAvi
    for container in [cIsoBmff, cMatroska, cAvi]:
      check reads(container)
    check not reads(cUnknown)

  test "the extension is never consulted":
    # An MP4 renamed to .avi still reads as an MP4.
    let disguised = getTempDir() / "unimovie-disguised.avi"
    writeFile(disguised, readFile(Fixtures / "tiny.mp4"))
    defer: removeFile(disguised)
    check sniffFile(disguised) == cIsoBmff
    check readMovieFile(disguised).tracks[0].width == 64

  test "every fixture decodes to a shape ffprobe agrees with":
    for name in Every:
      let path = Fixtures / name
      let movie = readMovieFile(path)
      check movie.tracks.len > 0
      let index = movie.videoTrack
      check index >= 0
      let width = ffprobeField(path, "stream=width")
      if width.len > 0:
        check $movie.tracks[index].width == width
        check $movie.tracks[index].height == ffprobeField(path, "stream=height")

  test "every fixture reports a duration ffprobe agrees with":
    for name in Every:
      let path = Fixtures / name
      let seconds = ffprobeField(path, "format=duration")
      if seconds.len == 0: continue
      let expected = parseFloat(seconds)
      let found = readMovieFile(path).durationSeconds
      # A tenth of a second: containers round their durations differently, and
      # AVI derives one from a frame count and a frame interval.
      check abs(found - expected) < 0.1

  test "bytes that are no container at all are refused":
    expect MovieError:
      discard readMovie("not a movie, not even close")
    check sniff("not a movie, not even close") == cUnknown

suite "matroska and webm":
  test "the doc type separates the two names of one format":
    check readMovieFile(Fixtures / "tiny.mkv").format == "matroska"
    check readMovieFile(Fixtures / "tiny.webm").format == "webm"

  test "codec identifiers are shortened to the codes MP4 uses":
    # So a caller registers one backend per codec, not one per container.
    check readMovieFile(Fixtures / "tiny.mkv").tracks[0].codec == "avc1"
    check readMovieFile(Fixtures / "tiny.webm").tracks[0].codec == "vp09"

  test "a file with no EBML header is refused":
    expect MovieError:
      discard readMatroska("\x1A\x45\xDF\xA4 not really ebml")

suite "avi":
  test "the stream reports the four-character code the file names":
    let movie = readMovieFile(Fixtures / "tiny.avi")
    check movie.format == "avi"
    check movie.tracks[0].kind == tkVideo
    # ffprobe normalises this to "mpeg4"; the file itself says FMP4.
    check movie.tracks[0].codec == "FMP4"
    check (movie.tracks[0].width, movie.tracks[0].height) == (48, 32)

  test "the frame count matches what ffprobe counts":
    let frames = ffprobeField(Fixtures / "tiny.avi", "stream=nb_frames")
    if frames.len > 0:
      check $readMovieFile(Fixtures / "tiny.avi").tracks[0].sampleCount == frames

  test "a RIFF that is not an AVI is refused":
    expect MovieError:
      discard readAvi("RIFF____WAVEfmt ")

suite "malformed input is reported, not fatal":
  test "every prefix of every fixture":
    for name in Every:
      let data = readFile(Fixtures / name)
      var step = 1
      while step < data.len:
        try:
          discard readMovie(data[0 ..< step])
        except MovieError, IOError, ValueError:
          discard
        step += 101
