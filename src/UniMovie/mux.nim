# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Writing an MP4: boxes around samples somebody else encoded.
##
## The symmetric half of `isobmff`. It assembles `ftyp`, `mdat` and the `moov`
## tables that say where each sample sits — and it never produces a sample. The
## caller hands over bytes that a system encoder, or any other encoder, already
## produced; this only says where they are.
##
## That is what keeps it free of any patent question. ISO 14496-12 describes the
## container and nothing here implements a codec. The file that comes out does
## hold a coded stream, so whoever ran the encoder carries whatever obligation
## that stream carries — the same position `isobmff` takes for reading.
##
## Samples are written as they arrive and `moov` is written at `close`, because
## the tables cannot be sized until the last sample is in. A two-hour recording
## therefore costs its sample table in memory, not its media.

import std/streams
import contracts
import UniImage/exif/isobmff
import ./types

const
  MaxWriterTracks* = 8
    ## More than a muxer built for a camera or a renderer needs. A caller
    ## asking for more is refused rather than allocated for.
  MaxWriterSamples* = 1 shl 24
    ## Sixteen million samples is days of video. The bound is on the sample
    ## table this holds in memory, not on the media written past it.
  MaxWriterEdits* = 1024
    ## An edit list is a handful of entries in every file that has one at all;
    ## a caller asking for more is refused rather than allocated for.

type
  Edit* = object
    ## One entry of a track's edit list: which stretch of its media plays, and
    ## for how long on the presentation clock.
    ##
    ## Two shapes cover almost every real use. An **empty edit** — `mediaTime`
    ## of -1 — holds the track blank for `duration`, which is how a track that
    ## starts late stays in sync with one that does not. A **trim** —
    ## `mediaTime` of *n* — starts playback *n* units into the media, which is
    ## how an encoder's own priming samples are kept out of what is heard.
    ##
    ## The media rate is always 1. A rate other than 1 asks a player to
    ## resample, which is a decision about the content rather than about the
    ## container, and leaving it out means no caller writes 0 by forgetting to
    ## set it.
    duration*: int64
      ## How long this edit lasts, in the **movie** timescale — milliseconds.
      ## Zero means the rest of the track: the whole media duration for a trim,
      ## which a caller cannot compute before the last sample is written.
    mediaTime*: int64
      ## Where in the media this edit starts, in the **track's** timescale, or
      ## -1 for an empty edit that plays nothing.

  TrackParams* = object
    ## What a track is, before any sample of it exists.
    kind*: TrackKind
    codec*: string
      ## The four-character code the sample entry is named after — `avc1`,
      ## `hvc1`, `av01`, `mp4a`, `alac`. It is what a reader reports and what a
      ## decoder backend is registered under, so it must match the bytes.
    timescale*: int
      ## Units per second every timestamp of this track is counted in. A video
      ## track usually takes the frame rate times a small factor so that a
      ## variable frame interval stays exact; audio takes the sample rate.
    width*, height*: int ## pixels; video only
    channels*: int ## audio only
    sampleRate*: int ## audio only, in hertz
    configKind*: string
      ## The four-character name of the codec configuration box inside the
      ## sample entry — `avcC` for H.264, `hvcC` for HEVC, `av1C` for AV1,
      ## `esds` for AAC, `alac` for Apple Lossless. Empty writes no such box,
      ## which suits a codec that needs none.
    config*: string
      ## That box's payload, exactly as the encoder produced it. Never parsed
      ## here: a parameter set is the decoder's business, and copying it
      ## unexamined is what keeps this a muxer.
    edits*: seq[Edit]
      ## The track's edit list, or empty for none — which is what a track whose
      ## media starts at zero and plays through wants, and writes no `edts` box
      ## at all.

  Sample = object
    size: int
    offset: int64
    duration: int
    keyframe: bool
    compositionOffset: int

  Mp4Writer* = object
    ## An open sink and one growing sample table per track.
    stream: Stream
    params: seq[TrackParams]
    samples: seq[seq[Sample]]
    chunks: seq[seq[tuple[track, first, count: int; offset: int64]]]
    lastTrack: int
    position: int64 ## where the next sample lands, from the file's start
    mdatAt: int64   ## where the mdat box header sits, for patching its size
    closed: bool
    ownsStream: bool
      ## Whether `close` should close the stream as well as finish the file.
      ## True only for the path constructor: a caller that passed its own
      ## stream keeps it, and closing a `StringStream` discards its data.

func mediaHandler(kind: TrackKind): string =
  ## The handler code `hdlr` carries for a track of this kind. `tkOther` is
  ## refused before it reaches here, so it has no code.
  case kind
  of tkVideo: "vide"
  of tkAudio: "soun"
  of tkOther: ""

proc newMp4Writer*(stream: Stream; tracks: openArray[TrackParams]): Mp4Writer
    {.contractual.} =
  ## Write the file header into `stream`, ready for samples.
  ##
  ## Every track is declared up front because `moov` names them in order and a
  ## sample refers to its track by that position.
  ##
  ## The stream may be a file or a string: `close` seeks back to patch `mdat`'s
  ## length, which both support. A caller wanting the bytes rather than a file
  ## passes a `StringStream` and reads its data afterwards.
  require:
    tracks.len in 1 .. MaxWriterTracks
  body:
    for track in tracks:
      if track.kind == tkOther:
        raise newException(MovieError, "mp4: a track must be video or audio")
      if track.codec.len != 4:
        raise newException(MovieError,
          "mp4: a codec is four characters, not '" & track.codec & "'")
      if track.timescale notin 1 .. 1_000_000_000:
        raise newException(MovieError, "mp4: implausible timescale")
      if track.kind == tkVideo and
          (track.width notin 1 .. MaxDimension or
           track.height notin 1 .. MaxDimension):
        raise newException(MovieError, "mp4: a video track needs its size")
      if track.edits.len > MaxWriterEdits:
        raise newException(MovieError, "mp4: implausible edit list")
      for edit in track.edits:
        # Both fields go into the file as 32 bits, and -1 is the one negative
        # media time the format gives a meaning to.
        if edit.duration notin 0'i64 .. high(uint32).int64:
          raise newException(MovieError, "mp4: an edit duration is out of range")
        if edit.mediaTime < -1 or edit.mediaTime > high(int32).int64:
          raise newException(MovieError, "mp4: an edit media time is out of range")

    if stream == nil:
      raise newException(IOError, "mp4: no stream to write to")
    result.stream = stream
    result.params = @tracks
    result.samples = newSeq[seq[Sample]](tracks.len)
    result.chunks = newSeq[seq[tuple[track, first, count: int; offset: int64]]](
      tracks.len)
    result.lastTrack = -1

    # `mp42` rather than `isom`: it is the brand that says the file may hold
    # anything ISO 14496-14 allows, which is what an arbitrary coded stream is.
    let ftyp = box("ftyp", "mp42\0\0\0\0mp42isomavc1")
    result.stream.write(ftyp)
    result.mdatAt = int64(ftyp.len)
    # A 32-bit size, patched at close. Streaming muxers write the largest
    # possible box and shrink it; this writes the real size once it is known,
    # which needs one seek and no wasted bytes.
    result.stream.write("\0\0\0\0mdat")
    result.position = result.mdatAt + 8

proc newMp4Writer*(path: string; tracks: openArray[TrackParams]): Mp4Writer
    {.contractual.} =
  ## `newMp4Writer` over a file. A path that cannot be opened for writing raises
  ## `IOError`.
  require:
    path.len > 0
    tracks.len in 1 .. MaxWriterTracks
  body:
    let stream = openFileStream(path, fmWrite)
    if stream == nil:
      raise newException(IOError, "mp4: cannot write " & path)
    result = newMp4Writer(stream, tracks)
    result.ownsStream = true

proc writeSample*(writer: var Mp4Writer; track: int; data: openArray[byte];
                  duration: int; keyframe = true; compositionOffset = 0)
    {.contractual.} =
  ## Append one coded sample to `track`, `duration` units of that track's
  ## timescale long.
  ##
  ## `keyframe` says the sample decodes on its own, which is what `stss`
  ## records and what a player seeks to; for audio every sample is one.
  ## `compositionOffset` is how far the sample's display time sits from its
  ## decode time — non-zero only where an encoder reorders, and written to
  ## `ctts` when any sample carries one.
  ##
  ## The bytes are copied verbatim. Nothing here reads them, so a caller may
  ## hand over whatever its encoder produced.
  require:
    track >= 0
    duration >= 0
  body:
    if writer.closed: raise newException(MovieError, "mp4: writer is closed")
    if track >= writer.params.len:
      raise newException(MovieError, "mp4: track index past the file")
    if writer.samples[track].len >= MaxWriterSamples:
      raise newException(MovieError, "mp4: too many samples for one track")
    if data.len == 0:
      raise newException(MovieError, "mp4: an empty sample has no meaning")

    # A chunk is a run of consecutive samples of one track. Starting a new one
    # only when the track changes keeps `stco` short: one offset per run rather
    # than one per sample, which for an hour of interleaved video and audio is
    # the difference between a few thousand entries and a few hundred thousand.
    if writer.lastTrack != track or writer.chunks[track].len == 0:
      writer.chunks[track].add (track, writer.samples[track].len, 0,
                                writer.position)
      writer.lastTrack = track
    writer.chunks[track][^1].count += 1

    writer.samples[track].add Sample(size: data.len, offset: writer.position,
      duration: duration, keyframe: keyframe,
      compositionOffset: compositionOffset)
    if data.len > 0:
      writer.stream.writeData(unsafeAddr data[0], data.len)
    writer.position += int64(data.len)


func runLengths(samples: seq[Sample]): string =
  ## `stts`: sample durations, run-length coded. A constant frame rate collapses
  ## to one entry however long the recording; a variable one costs an entry per
  ## change, which is what the table is shaped for.
  var runs: seq[tuple[count, duration: int]]
  for sample in samples:
    if runs.len > 0 and runs[^1].duration == sample.duration:
      runs[^1].count += 1
    else:
      runs.add (1, sample.duration)
  result.putBE(int64(runs.len), 4)
  for run in runs:
    result.putBE(int64(run.count), 4)
    result.putBE(int64(run.duration), 4)

func compositionOffsets(samples: seq[Sample]): string =
  ## `ctts`: how far each sample's display time sits from its decode time,
  ## run-length coded like `stts`. Returns "" when every offset is zero, so a
  ## stream the encoder did not reorder carries no such box at all.
  var any = false
  for sample in samples:
    if sample.compositionOffset != 0: any = true; break
  if not any: return ""
  var runs: seq[tuple[count, offset: int]]
  for sample in samples:
    if runs.len > 0 and runs[^1].offset == sample.compositionOffset:
      runs[^1].count += 1
    else:
      runs.add (1, sample.compositionOffset)
  result.putBE(int64(runs.len), 4)
  for run in runs:
    result.putBE(int64(run.count), 4)
    result.putBE(int64(run.offset), 4)

func syncSamples(samples: seq[Sample]): string =
  ## `stss`: which samples decode on their own, one-based. Returns "" when they
  ## all do — the absence of the box means exactly that, and writing it out in
  ## full would cost four bytes a sample to say nothing.
  var indices: seq[int]
  for index, sample in samples:
    if sample.keyframe: indices.add index + 1
  if indices.len == samples.len: return ""
  result.putBE(int64(indices.len), 4)
  for index in indices: result.putBE(int64(index), 4)

func sampleSizes(samples: seq[Sample]): string =
  ## `stsz`: one length per sample, or a single length when they all match —
  ## which they do for uncompressed audio and almost never for video.
  var uniform = samples.len > 0
  for sample in samples:
    if sample.size != samples[0].size: uniform = false; break
  if uniform:
    result.putBE(int64(samples[0].size), 4)
    result.putBE(int64(samples.len), 4)
  else:
    result.putBE(0, 4)
    result.putBE(int64(samples.len), 4)
    for sample in samples: result.putBE(int64(sample.size), 4)

func chunkTables(runs: seq[tuple[track, first, count: int; offset: int64]]):
    tuple[stsc, stco: string] =
  ## `stsc` maps a run of chunks to a samples-per-chunk count, and `stco` gives
  ## each chunk's byte offset. Consecutive chunks holding the same number of
  ## samples collapse into one `stsc` entry, which is the whole point of the
  ## table's shape.
  var entries: seq[tuple[firstChunk, perChunk: int]]
  for index, run in runs:
    if entries.len == 0 or entries[^1].perChunk != run.count:
      entries.add (index + 1, run.count)
  result.stsc.putBE(int64(entries.len), 4)
  for entry in entries:
    result.stsc.putBE(int64(entry.firstChunk), 4)
    result.stsc.putBE(int64(entry.perChunk), 4)
    result.stsc.putBE(1, 4) # every chunk uses sample description 1
  result.stco.putBE(int64(runs.len), 4)
  for run in runs: result.stco.putBE(run.offset, 4)

func sampleEntry(params: TrackParams): string =
  ## The `stsd` entry: what the samples are, and the codec's own configuration
  ## box inside it. The configuration is copied unexamined — reading it would
  ## be the decoder's job, not a muxer's.
  var entry: string
  entry.putBE(0, 6) # reserved
  entry.putBE(1, 2) # data reference index
  if params.kind == tkVideo:
    entry.putBE(0, 16) # pre-defined and reserved
    entry.putBE(int64(params.width), 2)
    entry.putBE(int64(params.height), 2)
    entry.putBE(0x0048_0000, 4) # 72 dpi horizontal, as 16.16
    entry.putBE(0x0048_0000, 4) # and vertical
    entry.putBE(0, 4) # reserved
    entry.putBE(1, 2) # one frame per sample
    entry.putBE(0, 32) # compressor name, 32 bytes of nothing
    entry.putBE(0x0018, 2) # 24-bit colour
    entry.putBE(0xFFFF, 2) # no colour table
  else:
    entry.putBE(0, 8) # reserved
    entry.putBE(int64(max(params.channels, 1)), 2)
    entry.putBE(16, 2) # sample size, as the format expects
    entry.putBE(0, 4) # pre-defined and reserved
    entry.putBE(int64(max(params.sampleRate, 1)) shl 16, 4) # 16.16 fixed point
  if params.configKind.len == 4:
    entry.add box(params.configKind, params.config)
  var stsd: string
  stsd.putBE(1, 4) # one entry
  stsd.add box(params.codec, entry)
  stsd


const MovieTimescale = 1000
  ## The movie header counts in milliseconds. Each track keeps its own, finer,
  ## timescale; this one only has to express the whole presentation's length.

func trackBox(params: TrackParams; samples: seq[Sample];
              runs: seq[tuple[track, first, count: int; offset: int64]];
              trackId: int): string =
  ## One `trak`: the track header, the media header, what it carries, and the
  ## five tables that say where its samples are.
  var mediaDuration = 0'i64
  for sample in samples: mediaDuration += int64(sample.duration)
  let seconds = if params.timescale > 0:
                  float(mediaDuration) / float(params.timescale)
                else: 0.0
  let movieDuration = int64(seconds * float(MovieTimescale))

  const identity = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]
  var tkhd: string
  tkhd.putBE(0, 8) # creation and modification time, unset
  tkhd.putBE(int64(trackId), 4)
  tkhd.putBE(0, 4) # reserved
  tkhd.putBE(movieDuration, 4)
  tkhd.putBE(0, 8) # reserved
  tkhd.putBE(0, 2) # layer
  tkhd.putBE(0, 2) # alternate group
  tkhd.putBE(if params.kind == tkAudio: 0x0100 else: 0, 2) # volume
  tkhd.putBE(0, 2) # reserved
  for value in identity: tkhd.putBE(int64(value), 4)
  tkhd.putBE(int64(params.width) shl 16, 4) # 16.16, zero for audio
  tkhd.putBE(int64(params.height) shl 16, 4)

  var mdhd: string
  mdhd.putBE(0, 8)
  mdhd.putBE(int64(params.timescale), 4)
  mdhd.putBE(mediaDuration, 4)
  mdhd.putBE(0x55C4, 2) # "und": no language claimed
  mdhd.putBE(0, 2) # pre-defined

  var hdlr: string
  hdlr.putBE(0, 4) # pre-defined
  hdlr.add mediaHandler(params.kind)
  hdlr.putBE(0, 12) # reserved
  hdlr.add '\0' # an empty name

  var dref: string
  dref.putBE(1, 4)
  dref.add box("url ", "\0\0\0\1") # self-contained: the media is in this file
  let dinf = box("dinf", fullBox("dref", dref))

  # A video track carries a video media header, an audio track a sound one.
  # Which of the two is the only structural difference between them here.
  let mediaHeader =
    if params.kind == tkVideo: fullBox("vmhd", "\0\0\0\0\0\0\0\0")
    else: fullBox("smhd", "\0\0\0\0")

  let tables = chunkTables(runs)
  var stbl = fullBox("stsd", sampleEntry(params)) &
             fullBox("stts", runLengths(samples)) &
             fullBox("stsc", tables.stsc) &
             fullBox("stsz", sampleSizes(samples)) &
             fullBox("stco", tables.stco)
  let sync = syncSamples(samples)
  if sync.len > 0: stbl.add fullBox("stss", sync)
  let offsets = compositionOffsets(samples)
  if offsets.len > 0: stbl.add fullBox("ctts", offsets)

  let minf = box("minf", mediaHeader & dinf & box("stbl", stbl))
  let mdia = box("mdia", fullBox("mdhd", mdhd) & fullBox("hdlr", hdlr) & minf)

  # `edts` sits between the track header and the media, and only when the
  # caller asked for one: a track with no edit list plays its media from the
  # start, which is what its absence already says.
  var edts: string
  if params.edits.len > 0:
    var elst: string
    elst.putBE(int64(params.edits.len), 4)
    for edit in params.edits:
      # A zero duration means the rest of the track, which is a length only
      # known now that every sample is in.
      let span = if edit.duration > 0: edit.duration else: movieDuration
      elst.putBE(span, 4)
      elst.putBE(edit.mediaTime, 4) # -1 writes as 0xFFFFFFFF, the empty edit
      elst.putBE(0x0001_0000, 4) # media rate 1.0, as 16.16
    edts = box("edts", fullBox("elst", elst))
  box("trak", fullBox("tkhd", tkhd) & edts & mdia)

proc close*(writer: var Mp4Writer) {.contractual.} =
  ## Write `moov` and close the file. The writer is spent afterwards.
  ##
  ## `moov` goes after `mdat` because the tables cannot be sized until the last
  ## sample is in. A reader finds it either way — the format says where boxes
  ## are, never in which order — and writing it first would mean either two
  ## passes over the media or a guess at how large it will be.
  ##
  ## The stream is closed only when this writer opened it. A caller that passed
  ## its own keeps it: closing a `StringStream` discards the data, which is
  ## exactly what a caller wanting the bytes came for.
  require:
    not writer.closed
  body:
    writer.closed = true
    var empty = true
    for track in writer.samples:
      if track.len > 0: empty = false; break
    if empty:
      if writer.ownsStream: writer.stream.close()
      raise newException(MovieError, "mp4: no sample was written")

    var longest = 0'i64
    for index, params in writer.params:
      var media = 0'i64
      for sample in writer.samples[index]: media += int64(sample.duration)
      if params.timescale > 0:
        let ms = int64(float(media) / float(params.timescale) *
                       float(MovieTimescale))
        if ms > longest: longest = ms

    const identity = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]
    var mvhd: string
    mvhd.putBE(0, 8) # creation and modification time, unset
    mvhd.putBE(MovieTimescale, 4)
    mvhd.putBE(longest, 4)
    mvhd.putBE(0x00010000, 4) # rate 1.0
    mvhd.putBE(0x0100, 2) # volume 1.0
    mvhd.putBE(0, 10) # reserved
    for value in identity: mvhd.putBE(int64(value), 4)
    mvhd.putBE(0, 24) # pre-defined
    mvhd.putBE(int64(writer.params.len + 1), 4) # next track id

    var moov = fullBox("mvhd", mvhd)
    for index, params in writer.params:
      if writer.samples[index].len == 0: continue
      moov.add trackBox(params, writer.samples[index], writer.chunks[index],
                        index + 1)
    writer.stream.write(box("moov", moov))

    # Patch mdat's length, now that the media is all in.
    let mdatSize = writer.position - writer.mdatAt
    writer.stream.setPosition(int(writer.mdatAt))
    var size: string
    size.putBE(mdatSize, 4)
    writer.stream.write(size)
    if writer.ownsStream: writer.stream.close()

proc trackCount*(writer: Mp4Writer): int =
  ## How many tracks the writer was opened for.
  writer.params.len

proc sampleCount*(writer: Mp4Writer; track: int): int {.contractual.} =
  ## How many samples have been written to `track` so far.
  require:
    track >= 0
    track < writer.params.len
  body:
    writer.samples[track].len


