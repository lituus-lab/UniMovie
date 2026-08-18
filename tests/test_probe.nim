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
  # A transport stream makes ffprobe print the entry more than once, so take
  # the first non-empty line rather than the whole output.
  for line in output.splitLines():
    let value = line.strip()
    if value.len > 0: return value
  ""

const Every = ["tiny.mp4", "av.mp4", "rotated.mov", "tiny.mkv", "tiny.webm",
               "tiny.avi", "tiny.ts", "tiny.ogv"]

suite "one entry point over every container":
  test "each fixture is recognised from its bytes":
    check sniffFile(Fixtures / "tiny.mp4") == cIsoBmff
    check sniffFile(Fixtures / "rotated.mov") == cIsoBmff
    check sniffFile(Fixtures / "tiny.mkv") == cMatroska
    check sniffFile(Fixtures / "tiny.webm") == cMatroska
    check sniffFile(Fixtures / "tiny.avi") == cAvi
    check sniffFile(Fixtures / "tiny.ts") == cMpegTs
    check sniffFile(Fixtures / "tiny.ogv") == cOgg
    for container in [cIsoBmff, cMatroska, cAvi, cMpegTs, cOgg]:
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

proc le32(value: uint32): string =
  ## Four little-endian bytes, which is how every AVI field is written.
  for index in 0 .. 3: result.add char((value shr (8 * index)) and 0xFF)

proc chunk(id, payload: string): string =
  ## A RIFF chunk: the four-character id, the payload length, the payload.
  ## Odd-length payloads are padded, as the format requires.
  result = id & le32(uint32(payload.len)) & payload
  if payload.len mod 2 == 1: result.add '\0'

proc riffWith(body: string): string =
  ## A RIFF file whose form is `AVI ` and whose content is `body`.
  chunk("RIFF", "AVI " & body)

proc strh(kind: string; scale, rate, length: uint32): string =
  ## A `strh` header: the stream kind, then the rate fields at the offsets
  ## the reader takes them from. Forty bytes, which is its minimum.
  result = kind & "FMP4" & le32(0) & le32(0) & le32(0)
  result.add le32(scale) & le32(rate) & le32(0) & le32(length)
  while result.len < 40: result.add '\0'

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

  test "a duration no int64 holds is refused rather than wrapped":
    # Both factors are 32-bit header fields, so their product can pass what
    # int64 holds. An unchecked build wraps it into a negative duration and
    # says nothing — which is why this is a check in the reader and asserted
    # here, rather than left to overflow checking that -d:release turns off.
    var avih = le32(0xFFFFFFFF'u32) # microSecPerFrame
    avih.add le32(0) & le32(0) & le32(0) # maxBytesPerSec, padding, flags
    avih.add le32(0xFFFFFFFF'u32) # totalFrames
    avih.add le32(0) & le32(0) & le32(0) # initialFrames, streams, bufferSize
    avih.add le32(64) & le32(48) # width, height
    expect MovieError:
      discard readAvi(riffWith(chunk("LIST", "hdrl" & chunk("avih", avih))))

  test "a media chunk named in upper case is still media":
    # The two-character suffix says what a chunk holds. A muxer is free to
    # write `DC`, and a reader that knew only `dc` would report a file with
    # no frames in it at all.
    let hdrl = chunk("LIST", "hdrl" &
      chunk("avih", le32(1000) & le32(0) & le32(0) & le32(0) & le32(1) &
                    le32(0) & le32(0) & le32(0) & le32(64) & le32(48)) &
      chunk("LIST", "strl" & chunk("strh", strh("vids", 1, 25, 1))))
    let upper = riffWith(hdrl & chunk("LIST", "movi" & chunk("00DC", "abcd")))
    let lower = riffWith(hdrl & chunk("LIST", "movi" & chunk("00dc", "abcd")))
    check codedSampleCount(upper, 0) == 1
    check codedSampleCount(upper, 0) == codedSampleCount(lower, 0)
    check codedSample(upper, 0, 0) == "abcd"

  test "a chunk is bounded by its parent, not by a fixed ceiling":
    # What limits a chunk is the span its parent actually holds. A media
    # list in a real recording runs past any round number, so a fixed cap
    # would end the walk and report a file with no frames in it.
    let hdrl = chunk("LIST", "hdrl" &
      chunk("avih", le32(1000) & le32(0) & le32(0) & le32(0) & le32(1) &
                    le32(0) & le32(0) & le32(0) & le32(64) & le32(48)) &
      chunk("LIST", "strl" & chunk("strh", strh("vids", 1, 25, 1))))
    let payload = "0123456789"
    let fits = riffWith(hdrl & chunk("LIST", "movi" & chunk("00dc", payload)))
    check codedSampleCount(fits, 0) == 1
    check codedSample(fits, 0, 0) == payload
    # The same chunk claiming one byte more than the list carries: refused,
    # and the walk ends rather than reading past what it was handed.
    let lying = fits.replace("00dc" & le32(uint32(payload.len)),
                             "00dc" & le32(uint32(payload.len + 1)))
    check codedSampleCount(lying, 0) == 0

  test "a palette chunk is not returned as a frame, in either case":
    # `pc` belongs to the stream without being a sample of it. Excluded by
    # the same rule whichever case it is written in, since what the reader
    # holds is a list of what media is rather than of what it is not.
    let hdrl = chunk("LIST", "hdrl" &
      chunk("avih", le32(1000) & le32(0) & le32(0) & le32(0) & le32(1) &
                    le32(0) & le32(0) & le32(0) & le32(64) & le32(48)) &
      chunk("LIST", "strl" & chunk("strh", strh("vids", 1, 25, 1))))
    for suffix in ["pc", "PC"]:
      let file = riffWith(hdrl &
        chunk("LIST", "movi" & chunk("00" & suffix, "abcd")))
      check codedSampleCount(file, 0) == 0

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

suite "mpeg transport stream":
  test "streams are found through the program tables":
    let movie = readMovieFile(Fixtures / "tiny.ts")
    check movie.format == "mpegts"
    check movie.tracks.len == 1
    check movie.tracks[0].kind == tkVideo
    check movie.tracks[0].codec == "avc1"
    # The PID, not a position: a transport stream identifies a stream by it.
    check movie.tracks[0].id > 0

  test "the picture size comes from the sequence parameter set":
    # A transport stream does not carry dimensions; they are in the coded
    # stream. Reading a parameter set produces no pixel, and ffprobe reaches
    # them the same way — so its answer is the check.
    let movie = readMovieFile(Fixtures / "tiny.ts")
    let width = ffprobeField(Fixtures / "tiny.ts", "stream=width")
    if width.len > 0:
      check $movie.tracks[0].width == width
      check $movie.tracks[0].height ==
        ffprobeField(Fixtures / "tiny.ts", "stream=height")

  test "the duration spans the timestamps plus one interval":
    # Ten frames at ten a second are 0.9 seconds apart and one second long.
    let movie = readMovieFile(Fixtures / "tiny.ts")
    check abs(movie.durationSeconds - 1.0) < 0.05

  test "bytes with no packet rhythm are not mistaken for a stream":
    check not isMpegTs("G" & repeat("x", 1000))
    expect MovieError:
      discard readMpegTs("G" & repeat("x", 1000))

suite "ogg":
  test "a logical stream is identified by its first packet":
    let movie = readMovieFile(Fixtures / "tiny.ogv")
    check movie.format == "ogg"
    check movie.tracks.len == 1
    check movie.tracks[0].kind == tkVideo
    check movie.tracks[0].codec == "vp08"
    check (movie.tracks[0].width, movie.tracks[0].height) == (48, 32)

  test "the frame count is the packets less this codec's headers":
    # VP8 in Ogg has two header packets; Theora has three. Counting them as
    # frames would make every file longer than it is.
    let movie = readMovieFile(Fixtures / "tiny.ogv")
    check movie.tracks[0].sampleCount == 5
    check abs(movie.durationSeconds - 1.0) < 0.05

  test "bytes with no page at the start are refused":
    expect MovieError:
      discard readOgg("OggT not a page")

suite "unknown is not empty":
  test "only ISO base media reports keyframes, and never reports none":
    # An empty keyframes sequence means the container does not carry the index,
    # not that the track has no seekable point. ISO base media is the one that
    # does carry it, and there an absent stss means every sample qualifies.
    for name in ["tiny.mp4", "av.mp4", "rotated.mov"]:
      let movie = readMovieFile(Fixtures / name)
      for track in movie.tracks:
        check track.keyframes.len > 0
    for name in ["tiny.mkv", "tiny.webm", "tiny.avi", "tiny.ts", "tiny.ogv"]:
      let movie = readMovieFile(Fixtures / name)
      for track in movie.tracks:
        check track.keyframes.len == 0

  test "a duration is reported even where the sample count is not":
    # Which is why the duration, not the sample count, is what says whether a
    # file holds anything.
    for name in ["tiny.mkv", "tiny.ts"]:
      let movie = readMovieFile(Fixtures / name)
      check movie.tracks[0].sampleCount == 0
      check movie.durationSeconds > 0.5

suite "the paths the other suites do not reach":
  test "an AVI with sound reports its audio stream":
    # Every other AVI fixture is video only, so the `WAVEFORMATEX` branch went
    # unexercised. A format tag is a number rather than a four-character code,
    # so it is rendered as four hex digits rather than invented into a name:
    # 0001 is uncompressed PCM.
    let data = readFile(Fixtures / "sound.avi")
    let movie = readMovie(data)
    check movie.tracks.len == 2
    check movie.videoTrack == 0
    let audio = movie.audioTrack
    check audio == 1
    check movie.tracks[audio].kind == tkAudio
    check movie.tracks[audio].codec == "0001"
    check movie.tracks[audio].sampleCount > 0
    check codedSampleCount(data, audio) > 0

  test "sniffing a file that cannot be opened raises IOError":
    expect IOError:
      discard sniffFile(getTempDir() / "unimovie-there-is-no-such-file.mp4")

  test "an empty file is not any container":
    let target = getTempDir() /
      ("unimovie-empty-" & $getCurrentProcessId() & ".mp4")
    defer: removeFile(target)
    writeFile(target, "")
    check sniffFile(target) == cUnknown
    expect MovieError: discard readMovieFile(target)
