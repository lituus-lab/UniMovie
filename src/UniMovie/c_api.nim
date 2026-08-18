# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The C ABI. Built --app:staticlib/--app:lib --noMain --mm:arc -d:release.
## Keep in sync with include/UniMovie.h; tests/c links the header against the
## library, so a header that drifts fails to compile rather than at a caller.
##
## No Nim exception crosses this boundary: every entry point returns a status
## and puts the reason in `umov_last_error`. Out-of-range input is rejected,
## never clamped into range.

import ./types
import ./probe
import ./isobmff as bmff
import ./matroska as mkv
import ./mux

const UniMovieVersion = "0.1.0"

type MovieStatus = enum
  umovOk = 0
  umovErrArg = 1
  umovErrIo = 2
  umovErrFormat = 3

var lastError {.threadvar.}: string

proc umov_version(): cstring {.exportc, cdecl, dynlib.} =
  ## Static version string; do not free.
  cstring(UniMovieVersion)

proc umov_last_error(): cstring {.exportc, cdecl, dynlib.} =
  ## Most recent failure on this thread, "" when there is none.
  cstring(lastError)

proc umov_probe(path: cstring; trackCount, videoIndex, audioIndex: ptr cint;
                durationSeconds: ptr cdouble; format: ptr array[16, char]): cint
    {.exportc, cdecl, dynlib.} =
  ## Shape of a container: how many tracks, which is the first video and audio
  ## one (-1 when absent), the playing time in seconds, and the container's own
  ## name — "mp4", "mov", "matroska", "webm", "avi".
  ##
  ## `format` receives at most fifteen characters and a terminating zero, so
  ## the caller supplies sixteen bytes. Pass NULL for it when the name is not
  ## wanted; every other argument is required.
  if path == nil or trackCount == nil or videoIndex == nil or
      audioIndex == nil or durationSeconds == nil:
    lastError = "every argument but format must be non-null"
    return cint(umovErrArg)
  try:
    let movie = probe.readMovieFile($path)
    if format != nil:
      for position in 0 .. 15: format[][position] = '\0'
      for position in 0 ..< min(15, movie.format.len):
        format[][position] = movie.format[position]
    trackCount[] = cint(movie.tracks.len)
    videoIndex[] = cint(movie.videoTrack)
    audioIndex[] = cint(movie.audioTrack)
    durationSeconds[] = cdouble(
      if movie.timescale > 0: movie.durationSeconds else: 0.0)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

proc umov_track(path: cstring; index: cint; kind: ptr cint;
                codec: ptr array[5, char]; width, height, rotation: ptr cint;
                sampleCount, keyframeCount: ptr cint): cint
    {.exportc, cdecl, dynlib.} =
  ## One track's shape. `kind` is 0 video, 1 audio, 2 other. `codec` receives
  ## the container's own four-character code and a terminating zero, so the
  ## caller supplies five bytes. `rotation` is clockwise **degrees** — 0, 90,
  ## 180 or 270, not an ordinal — and ffprobe counts the same matrix
  ## anticlockwise, so its 90 is this library's 270.
  if path == nil or kind == nil or codec == nil or width == nil or
      height == nil or rotation == nil or sampleCount == nil or
      keyframeCount == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  if index < 0:
    lastError = "track index must not be negative"
    return cint(umovErrArg)
  try:
    let movie = probe.readMovieFile($path)
    if int(index) >= movie.tracks.len:
      lastError = "track index past the file"
      return cint(umovErrArg)
    let track = movie.tracks[int(index)]
    kind[] = cint(ord(track.kind))
    for position in 0 .. 4: codec[][position] = '\0'
    for position in 0 ..< min(4, track.codec.len):
      codec[][position] = track.codec[position]
    width[] = cint(track.width)
    height[] = cint(track.height)
    rotation[] = cint(ord(track.rotation))
    sampleCount[] = cint(track.sampleCount)
    keyframeCount[] = cint(track.keyframes.len)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)



proc umov_track_sizes(path: cstring; index: cint;
                      codedWidth, codedHeight: ptr cint): cint
    {.exportc, cdecl, dynlib.} =
  ## The size a track's decoder produces, which is not always the size it is
  ## shown at: `umov_track` reports the display one, and the two differ by the
  ## sample aspect ratio. Compare a decoded frame against this pair.
  ##
  ## Zero for a track whose container does not say, and for audio.
  if path == nil or codedWidth == nil or codedHeight == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  if index < 0:
    lastError = "track index must not be negative"
    return cint(umovErrArg)
  try:
    let movie = probe.readMovieFile($path)
    if int(index) >= movie.tracks.len:
      lastError = "track index past the file"
      return cint(umovErrArg)
    codedWidth[] = cint(movie.tracks[int(index)].codedWidth)
    codedHeight[] = cint(movie.tracks[int(index)].codedHeight)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

proc umov_sniff(path: cstring; format: ptr array[16, char]): cint
    {.exportc, cdecl, dynlib.} =
  ## Which container a file is, from its leading bytes only — "mp4",
  ## "matroska", "avi", "mpegts", "ogg", or "unknown".
  ##
  ## Reads the head of the file rather than demultiplexing it, so it answers
  ## for a file this build cannot read as well as for one it can.
  if path == nil or format == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  try:
    let name = $sniffFile($path)
    for position in 0 .. 15: format[][position] = '\0'
    for position in 0 ..< min(15, name.len): format[][position] = name[position]
    lastError = ""
    result = cint(umovOk)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

proc umov_coded_sample_count(path: cstring; track: cint; count: ptr cint): cint
    {.exportc, cdecl, dynlib.} =
  ## How many coded samples a track holds.
  ##
  ## ISO base media reads this from a table; every other container has to be
  ## walked to find out, and so does every call — there is nothing cached
  ## between them.
  if path == nil or count == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  if track < 0:
    lastError = "track index must not be negative"
    return cint(umovErrArg)
  try:
    count[] = cint(probe.codedSampleCount(readFile($path), int(track)))
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

proc umov_coded_sample(path: cstring; track, index: cint; buffer: ptr uint8;
                       capacity: csize_t; written: ptr csize_t): cint
    {.exportc, cdecl, dynlib.} =
  ## The coded bytes of one sample, exactly as the file holds them.
  ##
  ## Two calls: pass a null `buffer` to learn the size, then call again with
  ## one that large. `written` receives the size either way, and a buffer
  ## smaller than it is refused rather than filled part-way.
  ##
  ## The bytes come back in the form the container stores — an MP4 gives
  ## length-prefixed units where a transport stream gives start codes.
  ## Converting between them is the decoder backend's business.
  if path == nil or written == nil:
    lastError = "path and written must be non-null"
    return cint(umovErrArg)
  if track < 0 or index < 0:
    lastError = "indices must not be negative"
    return cint(umovErrArg)
  try:
    let sample = probe.codedSample(readFile($path), int(track), int(index))
    written[] = csize_t(sample.len)
    if buffer == nil:
      lastError = ""
      return cint(umovOk)
    if capacity < csize_t(sample.len):
      lastError = "buffer is smaller than the sample"
      return cint(umovErrArg)
    if sample.len > 0:
      copyMem(buffer, unsafeAddr sample[0], sample.len)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

proc umov_sample_timing(path: cstring; track: cint; durations,
                        compositionOffsets: ptr cint; capacity: cint;
                        written: ptr cint): cint {.exportc, cdecl, dynlib.} =
  ## Per-sample decode duration and composition offset, in the track's own
  ## timescale. ISO base media only; another container reports zero samples.
  ##
  ## Two calls, as above: null arrays learn the count. Both arrays are filled
  ## together, since a caller rewriting a track needs both — writing samples
  ## back without their offsets puts a reordered stream out of order.
  if path == nil or written == nil:
    lastError = "path and written must be non-null"
    return cint(umovErrArg)
  if track < 0:
    lastError = "track index must not be negative"
    return cint(umovErrArg)
  try:
    let data = readFile($path)
    if sniff(data) != cIsoBmff:
      written[] = 0
      lastError = ""
      return cint(umovOk)
    let timing = bmff.sampleTiming(data, int(track))
    written[] = cint(timing.len)
    if durations == nil or compositionOffsets == nil:
      lastError = ""
      return cint(umovOk)
    if capacity < cint(timing.len):
      lastError = "arrays are smaller than the sample count"
      return cint(umovErrArg)
    let durationsArray = cast[ptr UncheckedArray[cint]](durations)
    let offsetsArray = cast[ptr UncheckedArray[cint]](compositionOffsets)
    for position, entry in timing:
      durationsArray[position] = cint(entry.duration)
      offsetsArray[position] = cint(entry.compositionOffset)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

proc umov_edit_list(path: cstring; track: cint; durations,
                    mediaTimes: ptr int64; capacity: cint;
                    written: ptr cint): cint {.exportc, cdecl, dynlib.} =
  ## A track's edit list — what it says about when its media plays. ISO base
  ## media only; another container reports none.
  ##
  ## Durations are in the movie timescale and media times in the track's, which
  ## is how the boxes store them. A media time of -1 is an empty edit, which
  ## plays nothing for its duration.
  ##
  ## Two calls, as above. A remux that drops this plays out of sync rather than
  ## producing a malformed file.
  if path == nil or written == nil:
    lastError = "path and written must be non-null"
    return cint(umovErrArg)
  if track < 0:
    lastError = "track index must not be negative"
    return cint(umovErrArg)
  try:
    let data = readFile($path)
    if sniff(data) != cIsoBmff:
      written[] = 0
      lastError = ""
      return cint(umovOk)
    let edits = bmff.editList(data, int(track))
    written[] = cint(edits.len)
    if durations == nil or mediaTimes == nil:
      lastError = ""
      return cint(umovOk)
    if capacity < cint(edits.len):
      lastError = "arrays are smaller than the edit count"
      return cint(umovErrArg)
    let durationsArray = cast[ptr UncheckedArray[int64]](durations)
    let timesArray = cast[ptr UncheckedArray[int64]](mediaTimes)
    for position, edit in edits:
      durationsArray[position] = edit.duration
      timesArray[position] = edit.mediaTime
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)

# Writing. Unlike everything above, a writer holds state between calls, so it
# is reached by a handle rather than by a path. A handle belongs to the thread
# that opened it — `umov_last_error` is per-thread for the same reason.

type
  UmovWriterKind = enum
    umovWriterMp4 = 0
    umovWriterMp4Fragmented = 1
    umovWriterMatroska = 2
    umovWriterWebm = 3

  UmovTrackParams {.bycopy.} = object
    ## The C struct a caller fills in per track. Laid out to match
    ## `umov_track_params` in the header field for field.
    kind: cint
    codec: array[5, char]
    timescale: cint
    width, height: cint
    channels, sampleRate: cint
    configKind: array[5, char]
    config: ptr uint8
    configLen: csize_t
    editDurations: ptr int64
    editMediaTimes: ptr int64
    editCount: cint

  WriterSlot = object
    ## One open writer. The three kinds are different Nim types with the same
    ## job, so the slot is a variant rather than an inheritance hierarchy.
    ##
    ## `id` is the handle a caller holds, and it is never reused: the storage
    ## is, but a closed handle must not address whatever is opened next, or a
    ## caller that kept one past `close` writes into an unrelated file and is
    ## told nothing.
    id: int
    case kind: UmovWriterKind
    of umovWriterMp4: whole: Mp4Writer
    of umovWriterMp4Fragmented: fragmented: FragmentedMp4Writer
    of umovWriterMatroska, umovWriterWebm: matroska: MatroskaWriter
    live: bool

var writers {.threadvar.}: seq[WriterSlot]
var nextWriterId {.threadvar.}: int

proc cstringOf(field: array[5, char]): string =
  ## A fixed C field as a Nim string, stopping at the first zero.
  for character in field:
    if character == '\0': break
    result.add character

proc toTrackParams(source: UmovTrackParams): TrackParams =
  ## One C struct as the Nim type. The configuration bytes are copied, so the
  ## caller's buffer need not outlive the call.
  result.kind = case source.kind
    of 0: tkVideo
    of 1: tkAudio
    else: tkOther
  result.codec = cstringOf(source.codec)
  result.timescale = int(source.timescale)
  result.width = int(source.width)
  result.height = int(source.height)
  result.channels = int(source.channels)
  result.sampleRate = int(source.sampleRate)
  result.configKind = cstringOf(source.configKind)
  if source.config != nil and source.configLen > 0:
    result.config = newString(int(source.configLen))
    copyMem(addr result.config[0], source.config, int(source.configLen))
  if source.editDurations != nil and source.editMediaTimes != nil and
      source.editCount > 0:
    let durations = cast[ptr UncheckedArray[int64]](source.editDurations)
    let times = cast[ptr UncheckedArray[int64]](source.editMediaTimes)
    for index in 0 ..< int(source.editCount):
      result.edits.add Edit(duration: durations[index],
                            mediaTime: times[index])

proc umov_writer_open(path: cstring; kind: cint;
                      tracks: ptr UmovTrackParams; trackCount: cint;
                      handle: ptr cint): cint {.exportc, cdecl, dynlib.} =
  ## Open a writer of one of four shapes: a whole MP4, a fragmented one, a
  ## Matroska, or a WebM.
  ##
  ## Every track is declared here because the file names them in order and a
  ## sample refers to its track by that position. The handle that comes back is
  ## valid on this thread until `umov_writer_close`.
  ##
  ## Nothing is encoded. The caller hands over samples some encoder already
  ## produced, which is what keeps this side of the library clear of any codec.
  if path == nil or tracks == nil or handle == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  if kind notin 0 .. 3:
    lastError = "writer kind must be 0..3"
    return cint(umovErrArg)
  if trackCount <= 0:
    lastError = "a file needs at least one track"
    return cint(umovErrArg)
  try:
    let source = cast[ptr UncheckedArray[UmovTrackParams]](tracks)
    var params: seq[TrackParams]
    for index in 0 ..< int(trackCount):
      params.add toTrackParams(source[index])
    let writerKind = UmovWriterKind(kind)
    var slot = case writerKind
      of umovWriterMp4:
        WriterSlot(kind: writerKind, whole: newMp4Writer($path, params),
                   live: true)
      of umovWriterMp4Fragmented:
        WriterSlot(kind: writerKind,
                   fragmented: newFragmentedMp4Writer($path, params),
                   live: true)
      of umovWriterMatroska, umovWriterWebm:
        WriterSlot(kind: writerKind,
                   matroska: mkv.newMatroskaWriter($path, params,
                     webm = writerKind == umovWriterWebm),
                   live: true)
    # The storage of a closed slot is reused, so a long run of open and close
    # does not leak one entry per file; the identifier is not, so a handle kept
    # past `close` stays invalid rather than addressing the next file.
    inc nextWriterId
    slot.id = nextWriterId
    var found = -1
    for index, existing in writers:
      if not existing.live: found = index; break
    if found < 0: writers.add slot
    else: writers[found] = slot
    handle[] = cint(slot.id) # counted from one, so zero is never valid
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrArg)

proc slotOf(handle: cint): int =
  ## The slot a handle names, or -1 when it names none — which covers a handle
  ## that was never opened, one opened on another thread, and one already
  ## closed.
  ##
  ## Searched rather than indexed, because the identifier is not the position:
  ## the list holds only writers open at once, so it is a handful of entries.
  if handle <= 0: return -1
  for index, slot in writers:
    if slot.live and slot.id == int(handle): return index
  -1

proc umov_writer_sample(handle, track: cint; data: ptr uint8; length: csize_t;
                        duration, keyframe, compositionOffset: cint): cint
    {.exportc, cdecl, dynlib.} =
  ## Append one coded sample to a track, `duration` units of that track's
  ## timescale long.
  ##
  ## `keyframe` non-zero says the sample decodes on its own, which is what a
  ## player seeks to. `compositionOffset` is how far its display time sits from
  ## its decode time — non-zero only where an encoder reordered, and it must be
  ## passed through, or a reordered stream plays out of order.
  ##
  ## The bytes are copied before this returns.
  if data == nil or length == 0:
    lastError = "a sample needs bytes"
    return cint(umovErrArg)
  let index = slotOf(handle)
  if index < 0:
    lastError = "no writer with that handle is open on this thread"
    return cint(umovErrArg)
  if track < 0 or duration < 0:
    lastError = "track and duration must not be negative"
    return cint(umovErrArg)
  try:
    var bytes = newSeq[byte](int(length))
    copyMem(addr bytes[0], data, int(length))
    case writers[index].kind
    of umovWriterMp4:
      writers[index].whole.writeSample(int(track), bytes, int(duration),
        keyframe != 0, int(compositionOffset))
    of umovWriterMp4Fragmented:
      writers[index].fragmented.writeSample(int(track), bytes, int(duration),
        keyframe != 0, int(compositionOffset))
    of umovWriterMatroska, umovWriterWebm:
      writers[index].matroska.writeSample(int(track), bytes, int(duration),
        keyframe != 0, int(compositionOffset))
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrArg)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrArg)

proc umov_writer_flush(handle: cint): cint {.exportc, cdecl, dynlib.} =
  ## End the current fragment or cluster, so what has been written so far can
  ## be played on its own.
  ##
  ## A whole-file MP4 has no such boundary and succeeds without doing anything,
  ## which lets a caller write one loop for every kind. A fragment or cluster
  ## that does not start on a keyframe cannot be played alone, so where the
  ## boundary falls is the caller's decision and not this library's.
  let index = slotOf(handle)
  if index < 0:
    lastError = "no writer with that handle is open on this thread"
    return cint(umovErrArg)
  try:
    case writers[index].kind
    of umovWriterMp4: discard
    of umovWriterMp4Fragmented: writers[index].fragmented.flushFragment()
    of umovWriterMatroska, umovWriterWebm:
      writers[index].matroska.flushCluster()
    lastError = ""
    result = cint(umovOk)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrArg)

proc umov_writer_close(handle: cint): cint {.exportc, cdecl, dynlib.} =
  ## Finish the file and release the handle. The handle is invalid afterwards
  ## whether or not this succeeded, so a failure is reported rather than left
  ## to be retried.
  let index = slotOf(handle)
  if index < 0:
    lastError = "no writer with that handle is open on this thread"
    return cint(umovErrArg)
  try:
    case writers[index].kind
    of umovWriterMp4: writers[index].whole.close()
    of umovWriterMp4Fragmented: writers[index].fragmented.close()
    of umovWriterMatroska, umovWriterWebm: writers[index].matroska.close()
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrArg)
  finally:
    writers[index].live = false



proc umov_writer_counts(handle, track: cint; pending, flushed: ptr cint): cint
    {.exportc, cdecl, dynlib.} =
  ## How many samples of `track` are buffered for the next fragment or cluster,
  ## and how many boundaries have been written so far.
  ##
  ## `flushed` is fragments for a fragmented MP4 and cue points for a Matroska;
  ## a whole-file MP4 has neither and reports 0, with `pending` counting every
  ## sample written so far, since none of them has been sealed off.
  let index = slotOf(handle)
  if index < 0:
    lastError = "no writer with that handle is open on this thread"
    return cint(umovErrArg)
  if pending == nil or flushed == nil or track < 0:
    lastError = "counts must be non-null and the track index positive"
    return cint(umovErrArg)
  try:
    case writers[index].kind
    of umovWriterMp4:
      if int(track) >= writers[index].whole.trackCount:
        lastError = "track index past the file"
        return cint(umovErrArg)
      pending[] = cint(writers[index].whole.sampleCount(int(track)))
      flushed[] = 0
    of umovWriterMp4Fragmented:
      if int(track) >= writers[index].fragmented.trackCount:
        lastError = "track index past the file"
        return cint(umovErrArg)
      pending[] = cint(writers[index].fragmented.pendingSamples(int(track)))
      flushed[] = cint(writers[index].fragmented.fragmentCount)
    of umovWriterMatroska, umovWriterWebm:
      if int(track) >= writers[index].matroska.trackCount:
        lastError = "track index past the file"
        return cint(umovErrArg)
      # Matroska buffers one cluster rather than per track, so what is pending
      # is not a per-track number; the cue count is the useful half.
      pending[] = 0
      flushed[] = cint(writers[index].matroska.clusterCount)
    lastError = ""
    result = cint(umovOk)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrArg)



proc umov_location(path: cstring; latitude, longitude: ptr cdouble;
                   found: ptr cint): cint {.exportc, cdecl, dynlib.} =
  ## Where a recording says it was made.
  ##
  ## `found` is 0 when the file carries no position, which most do not and
  ## which is not a failure. Latitude 0, longitude 0 is a real point in the
  ## Atlantic, so a caller must read `found` rather than test the numbers.
  if path == nil or latitude == nil or longitude == nil or found == nil:
    lastError = "every argument must be non-null"
    return cint(umovErrArg)
  try:
    let where = locationFile($path)
    found[] = cint(if where.found: 1 else: 0)
    latitude[] = cdouble(where.latitude)
    longitude[] = cdouble(where.longitude)
    lastError = ""
    result = cint(umovOk)
  except MovieError as error:
    lastError = error.msg
    result = cint(umovErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(umovErrFormat)


