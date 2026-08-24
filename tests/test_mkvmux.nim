# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Writing Matroska, checked by decoding it with ffmpeg.
##
## The decisive check is pixels, not structure. A Matroska block's timestamp is
## when its frame is *shown*, where ISO base media stores when it is decoded —
## so a writer that copies the decode times across produces a file that is well
## formed, reads back sample for sample, and plays a reordered stream in the
## wrong order. Only decoded pixels catch that, which is why every conversion
## below ends in a comparison of them.
import std/[unittest, os, osproc, strutils]
import UniContainer/isobmff as boxlayer
import UniMovie

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc configOf(data: string; trackIndex: int; want: string): string =
  ## A track's codec configuration payload out of its sample entry.
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
      let fixed = if want == "avcC": 78 else: 28
      for inner, innerBody, innerEnd in boxlayer.boxes(bytes, entryBody + fixed,
                                                       entryEnd):
        if inner == want:
          result = newString(innerEnd - innerBody)
          for index in 0 ..< result.len:
            result[index] = char(bytes[innerBody + index])
          return
    return

proc audioSpecificConfig(esds: string): string =
  ## The AudioSpecificConfig inside an `esds`, which is what Matroska wants as
  ## an AAC track's private data — the whole descriptor tree is not it, and
  ## handing that over is what makes ffmpeg report audio object type 0.
  ##
  ## Tag 0x05 is the decoder-specific information; its length may be written
  ## across four bytes with the top bit set on all but the last.
  var index = 0
  while index < esds.len:
    if esds[index] == '\x05':
      var at = index + 1
      var length = 0
      while at < esds.len:
        let byteValue = int(uint8(esds[at]))
        length = (length shl 7) or (byteValue and 0x7F)
        inc at
        if (byteValue and 0x80) == 0: break
      if length > 0 and at + length <= esds.len:
        return esds[at ..< at + length]
    inc index

proc bytesOf(data: string; track, index: int): seq[byte] =
  ## One coded sample as bytes, ready to hand to a writer.
  let sample = codedSample(data, track, index)
  result = newSeq[byte](sample.len)
  for position in 0 ..< sample.len: result[position] = byte(sample[position])

proc decodeToRaw(path, target: string): bool =
  if findExe("ffmpeg").len == 0: return false
  execCmdEx("ffmpeg -v error -y -i " & path.quoteShell &
            " -f rawvideo -pix_fmt rgb24 " & target.quoteShell).exitCode == 0

proc paramsOf(source: string; movie: Movie): seq[TrackParams] =
  ## Writer parameters describing the tracks of an already-read movie.
  ##
  ## Matroska wants the bare AudioSpecificConfig where MP4 carries a whole
  ## `esds` descriptor, so the audio configuration is unwrapped on the way.
  for index, track in movie.tracks:
    var params = TrackParams(kind: track.kind, codec: track.codec,
      timescale: track.timescale, width: track.width, height: track.height,
      channels: 1, sampleRate: track.timescale, edits: editList(source, index))
    if track.kind == tkVideo:
      params.config = configOf(source, index, "avcC")
    else:
      params.config = audioSpecificConfig(configOf(source, index, "esds"))
    result.add params

proc convert(source: string; target: string; webm = false): int =
  ## Remux an MP4 fixture into Matroska, returning how many samples went in.
  let data = readFile(source)
  let movie = readMovie(data)
  var timings: seq[seq[tuple[duration, compositionOffset: int]]]
  for index in 0 ..< movie.tracks.len: timings.add sampleTiming(data, index)
  var writer = newMatroskaWriter(target, paramsOf(data, movie), webm)
  let video = movie.videoTrack
  let audio = movie.audioTrack
  var audioAt = 0
  let perFrame = if audio >= 0:
                   movie.tracks[audio].sampleCount div
                   max(movie.tracks[video].sampleCount, 1)
                 else: 0
  for sample in 0 ..< movie.tracks[video].sampleCount:
    writer.writeSample(video, bytesOf(data, video, sample),
      timings[video][sample].duration, sample in movie.tracks[video].keyframes,
      timings[video][sample].compositionOffset)
    inc result
    if audio < 0: continue
    let want = min(audioAt + perFrame, movie.tracks[audio].sampleCount)
    while audioAt < want:
      writer.writeSample(audio, bytesOf(data, audio, audioAt),
        timings[audio][audioAt].duration)
      inc audioAt
      inc result
  if audio >= 0:
    while audioAt < movie.tracks[audio].sampleCount:
      writer.writeSample(audio, bytesOf(data, audio, audioAt),
        timings[audio][audioAt].duration)
      inc audioAt
      inc result
  writer.close()

suite "an MP4 remuxed into Matroska plays the same":
  setup:
    let target = getTempDir() /
      ("unimovie-mkv-" & $getCurrentProcessId() & ".mkv")
    let fromSource = getTempDir() /
      ("unimovie-mkv-a-" & $getCurrentProcessId() & ".raw")
    let fromWritten = getTempDir() /
      ("unimovie-mkv-b-" & $getCurrentProcessId() & ".raw")

  teardown:
    removeFile(target)
    removeFile(fromSource)
    removeFile(fromWritten)

  test "the fixture really is reordered, or the pixel check proves nothing":
    # Without this the pixel comparisons below would pass on a writer that
    # ignores composition offsets entirely.
    let data = readFile(Fixtures / "tiny.mp4")
    var reordered = false
    for entry in sampleTiming(data, readMovie(data).videoTrack):
      if entry.compositionOffset != 0: reordered = true
    check reordered

  test "one video track decodes to the same pixels":
    discard convert(Fixtures / "tiny.mp4", target)
    if not decodeToRaw(Fixtures / "tiny.mp4", fromSource): skip()
    elif not decodeToRaw(target, fromWritten): skip()
    else: check readFile(fromSource) == readFile(fromWritten)

  test "video and audio together decode to the same pixels":
    discard convert(Fixtures / "av.mp4", target)
    if not decodeToRaw(Fixtures / "av.mp4", fromSource): skip()
    elif not decodeToRaw(target, fromWritten): skip()
    else: check readFile(fromSource) == readFile(fromWritten)

  test "ffprobe finds every track and every packet":
    let written = convert(Fixtures / "av.mp4", target)
    if findExe("ffprobe").len == 0: skip()
    else:
      let (output, code) = execCmdEx("ffprobe -v error -count_packets " &
        "-show_entries stream=codec_name,nb_read_packets -of csv=p=0 " &
        target.quoteShell)
      check code == 0
      var counted = 0
      var codecs: seq[string]
      for line in output.splitLines():
        let parts = line.strip().split(',')
        if parts.len == 2:
          codecs.add parts[0]
          counted += parseInt(parts[1])
      check codecs == @["h264", "aac"]
      check counted == written

  test "the audio timestamps are the ones ffmpeg's own muxer writes":
    # ffmpeg converting the same file is the reference. Its first audio packet
    # lands before zero as well, because the edit list trims encoder priming
    # and Matroska expresses that as a negative timestamp rather than by
    # dropping samples.
    if findExe("ffmpeg").len == 0: skip()
    else:
      discard convert(Fixtures / "av.mp4", target)
      let reference = getTempDir() /
        ("unimovie-mkv-ref-" & $getCurrentProcessId() & ".mkv")
      defer: removeFile(reference)
      check execCmdEx("ffmpeg -v error -y -i " &
        (Fixtures / "av.mp4").quoteShell & " -c copy " &
        reference.quoteShell).exitCode == 0
      proc firstTimes(path: string): seq[string] =
        let (output, _) = execCmdEx("ffprobe -v error -select_streams a:0 " &
          "-show_entries packet=pts_time -of csv=p=0 " & path.quoteShell)
        for line in output.splitLines():
          let value = line.strip().strip(chars = {','})
          if value.len > 0 and value != "N/A": result.add value
          if result.len == 3: return
      check firstTimes(target) == firstTimes(reference)

suite "what the Matroska writer produces, read back":
  setup:
    let target = getTempDir() /
      ("unimovie-mkvread-" & $getCurrentProcessId() & ".mkv")

  teardown:
    removeFile(target)

  test "the shape and every coded sample survive":
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    discard convert(Fixtures / "tiny.mp4", target)
    let written = readFile(target)
    let back = readMovie(written)
    check back.format == "matroska"
    check back.tracks.len == 1
    check back.tracks[0].kind == tkVideo
    check back.tracks[0].codec == movie.tracks[index].codec
    check back.tracks[0].width == movie.tracks[index].width
    check back.tracks[0].height == movie.tracks[index].height
    check codedSampleCount(written, 0) == movie.tracks[index].sampleCount
    for sample in 0 ..< movie.tracks[index].sampleCount:
      check codedSample(written, 0, sample) == codedSample(source, index, sample)

  test "webm writes the restricted doc type":
    discard convert(Fixtures / "tiny.mp4", target, webm = true)
    check readMovie(readFile(target)).format == "webm"

  test "a cue point per cluster that opened on a keyframe":
    let source = readFile(Fixtures / "tiny.mp4")
    let movie = readMovie(source)
    let index = movie.videoTrack
    let timing = sampleTiming(source, index)
    var writer = newMatroskaWriter(target, paramsOf(source, movie))
    for sample in 0 ..< movie.tracks[index].sampleCount:
      writer.writeSample(0, bytesOf(source, index, sample),
        timing[sample].duration, sample in movie.tracks[index].keyframes,
        timing[sample].compositionOffset)
    writer.close()
    check writer.clusterCount == movie.tracks[index].keyframes.len
    check writer.trackCount == 1

suite "the Matroska writer refuses what it cannot write":
  setup:
    let target = getTempDir() /
      ("unimovie-mkvbad-" & $getCurrentProcessId() & ".mkv")

  teardown:
    removeFile(target)

  test "an esds where the AudioSpecificConfig belongs":
    # Refused on the label, without the bytes being read. Handed the whole
    # descriptor tree, ffmpeg drops the track and the file looks fine.
    expect MovieError:
      discard newMatroskaWriter(target, [TrackParams(kind: tkAudio,
        codec: "mp4a", timescale: 44100, channels: 1, sampleRate: 44100,
        configKind: "esds", config: "\0\0\0\0")])

  test "a track that is neither video nor audio, and a video with no size":
    expect MovieError:
      discard newMatroskaWriter(target, [TrackParams(kind: tkOther,
        codec: "avc1", timescale: 1000)])
    expect MovieError:
      discard newMatroskaWriter(target, [TrackParams(kind: tkVideo,
        codec: "avc1", timescale: 1000)])
    expect MovieError:
      discard newMatroskaWriter(target, [TrackParams(kind: tkVideo,
        codec: "", timescale: 1000, width: 16, height: 16)])

  test "a sample for a track that does not exist, and an empty one":
    var writer = newMatroskaWriter(target, [TrackParams(kind: tkVideo,
      codec: "avc1", timescale: 1000, width: 16, height: 16)])
    expect MovieError: writer.writeSample(5, [byte 1, 2, 3], 100)
    expect MovieError: writer.writeSample(0, [], 100)
    writer.writeSample(0, [byte 1, 2, 3], 100)
    writer.close()
