# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Correcting the timestamps an ISO base media file carries.
##
## A camera with a wrong clock stamps every recording it makes, and the date is
## written in three kinds of box: `mvhd` for the presentation, `tkhd` for each
## track, and `mdhd` for each track's media. All three hold it in a fixed-width
## field, so replacing it moves no bytes — which is what makes this safe. The
## sample tables in `stbl` are absolute file offsets into `mdat`; an edit that
## changed any box's size would invalidate every one of them.
##
## Nothing here re-encodes. The samples are not read, let alone touched.
##
## The epoch is 1904-01-01 UTC, not 1970 — QuickTime predates Unix time in the
## places that matter, and a reader that assumes otherwise is off by 66 years.

import contracts
import std/[options, os, strutils, times]
import UniContainer/isobmff
from ./isobmff import readMovieHeaderBytes

const Epoch1904* = 2_082_844_800'i64
  ## Seconds from 1904-01-01 to 1970-01-01, both UTC. An ISO base media
  ## timestamp counts from the former.

const MaxVersion0Timestamp = 4_294_967_295'i64
  ## A version 0 box holds 32 bits. A date beyond that cannot go into one, and
  ## truncating it would record a different year.

type
  MovieDateError* = object of CatchableError
    ## The file carries a date this module will not rewrite correctly. Raised
    ## rather than producing a file whose boxes disagree with each other.

proc toQuickTime*(moment: DateTime): int64 =
  ## A moment as an ISO base media timestamp.
  moment.toTime().toUnix() + Epoch1904

proc fromQuickTime*(stamp: int64): DateTime =
  ## The inverse. Only meaningful for a non-zero stamp: zero means unset, which
  ## is a different state from the start of 1904.
  fromUnix(stamp - Epoch1904).utc()

func beU32At(data: string; offset: int): int64 =
  ## Four big-endian bytes at `offset`. The caller has already bounded the
  ## span it hands in: this indexes without checking, because every use here
  ## follows a box header whose length was validated.
  (int64(uint8(data[offset])) shl 24) or
    (int64(uint8(data[offset + 1])) shl 16) or
    (int64(uint8(data[offset + 2])) shl 8) or int64(uint8(data[offset + 3]))

func beU64At(data: string; offset: int): int64 =
  ## Eight big-endian bytes at `offset`, for a version-1 header. Bounded by
  ## the caller, as `beU32At` is.
  result = 0
  for index in 0 ..< 8:
    result = (result shl 8) or int64(uint8(data[offset + index]))

proc putBE32(data: var string; offset: int; value: int64) =
  ## Write `value` as four big-endian bytes at `offset`, in place. The four
  ## bytes must already exist: this overwrites, it never grows the string.
  for index in 0 ..< 4:
    data[offset + index] = char(uint8((value shr ((3 - index) * 8)) and 0xFF))

proc putBE64(data: var string; offset: int; value: int64) =
  ## Write `value` as eight big-endian bytes at `offset`, in place. Same
  ## requirement as `putBE32`: the room is the caller's to have made.
  for index in 0 ..< 8:
    data[offset + index] = char(uint8((value shr ((7 - index) * 8)) and 0xFF))

type HeaderSpan = object
  ## Where one box keeps its creation time, and how wide the field is.
  at: int
  wide: bool

func creationField(data: string; body, bodyEnd: int): Option[HeaderSpan] =
  ## The creation-time field of an `mvhd`, `tkhd` or `mdhd`. All three open with
  ## a version-and-flags word followed by creation then modification time, so
  ## one reader serves the three.
  if body + 4 > bodyEnd: return
  let wide = int(uint8(data[body])) == 1
  let width = if wide: 8 else: 4
  # Both timestamps must fit, or the box is truncated and not worth guessing at.
  if body + 4 + width * 2 > bodyEnd: return
  some(HeaderSpan(at: body + 4, wide: wide))

func readCreation(data: string; span: HeaderSpan): int64 =
  ## The creation time a header carries, in seconds since the QuickTime epoch.
  ##
  ## The field is four bytes in a version-0 header and eight in a version-1
  ## one, which is what `span.wide` records — reading the wrong width would
  ## take half a timestamp and half the field after it.
  if span.wide: data.beU64At(span.at) else: data.beU32At(span.at)

const DateMarkers = ["\xA9day", "com.apple.quicktime.creationdate"]
  ## The two places a capture date is written as text: QuickTime's `©day` under
  ## `udta`, and Apple's key in the `keys`/`ilst` pair.

proc refuseSecondDate(data: string; moovBody, moovEnd: int) =
  ## Refuse a file that states the date a second time, as text.
  ##
  ## Those atoms are variable-length, so correcting them in place is not
  ## possible in general — and a file whose binary headers said one date while
  ## its text tag said another would show the old date in the software most
  ## likely to be reading it. Refused rather than half-done; doing it properly
  ## means rebuilding `moov` and every offset in `stbl`.
  ##
  ## The markers are looked for as bytes rather than by walking to them:
  ## `moov/meta` is a plain container in QuickTime and a versioned one under
  ## `udta`, so a structural search has two shapes to get right and this has
  ## none. A coincidental match costs a refusal, which is the safe direction for
  ## a check whose whole purpose is to not write a contradiction.
  let span = data[moovBody ..< moovEnd]
  for marker in DateMarkers:
    if span.contains(marker):
      raise newException(MovieDateError, "this file states the date a second " &
        "time in a variable-length atom (" &
        (if marker[0] == '\xA9': "\u00A9day" else: marker) &
        "); correcting only the headers would leave the two disagreeing")

proc headerSpans(data: string; moovBody, moovEnd: int): seq[HeaderSpan] =
  ## Every box in the presentation that carries a creation time.
  let mvhd = findBox(data.toOpenArrayByte(0, data.high), moovBody, moovEnd,
    ["mvhd"])
  if mvhd.body >= 0:
    let span = creationField(data, mvhd.body, mvhd.bodyEnd)
    if span.isSome: result.add span.get()
  for kind, body, bodyEnd in boxes(data.toOpenArrayByte(0, data.high), moovBody,
      moovEnd):
    if kind != "trak": continue
    # A track states its own date twice: once for the track, once for its media.
    # Leaving either behind is what makes a player disagree with a probe.
    for path in [@["tkhd"], @["mdia", "mdhd"]]:
      let box = findBox(data.toOpenArrayByte(0, data.high), body, bodyEnd, path)
      if box.body < 0: continue
      let span = creationField(data, box.body, box.bodyEnd)
      if span.isSome: result.add span.get()

proc setMovieCreationDate*(inPath, outPath: string;
                           moment: DateTime): int {.contractual.} =
  ## Write `moment` as the creation time of the presentation and of every track,
  ## and return how many boxes were changed.
  ##
  ## The modification time is left alone: it records when the file was last
  ## written, which is not what a wrong camera clock got wrong.
  ##
  ## The file is rebuilt in memory and written to a temporary beside the
  ## target, which is then renamed over it. So `outPath` may equal `inPath`,
  ## and a failure at any point — including part-way through the write —
  ## leaves the original as it was rather than truncated.
  ##
  ## Rebuilt in memory means the whole file is held at once. That is the cost
  ## of being able to write back over the input; a caller editing a recording
  ## rather than a clip should know it is paying it.
  require:
    inPath.len > 0
    outPath.len > 0
  body:
    var data = readFile(inPath)
    let moov = findBox(data.toOpenArrayByte(0, data.high), 0, data.len, ["moov"])
    if moov.body < 0:
      raise newException(MovieDateError,
        "no moov box: not an ISO base media file")
    refuseSecondDate(data, moov.body, moov.bodyEnd)

    let stamp = toQuickTime(moment)
    if stamp <= 0:
      raise newException(MovieDateError,
        "a date before 1904 cannot be written into an ISO base media header")

    let spans = headerSpans(data, moov.body, moov.bodyEnd)
    if spans.len == 0:
      raise newException(MovieDateError,
        "no mvhd, tkhd or mdhd box holds a timestamp this could replace")
    # Checked before the first write, so no file is left with some headers
    # updated and the rest not.
    for span in spans:
      if not span.wide and stamp > MaxVersion0Timestamp:
        raise newException(MovieDateError,
          "this date does not fit the 32-bit field this file uses")

    for span in spans:
      if span.wide: data.putBE64(span.at, stamp)
      else: data.putBE32(span.at, stamp)
    # Beside the target, not in the system temp directory: a rename is atomic
    # only within one filesystem, and those two are often not the same one.
    let scratch = outPath & ".unimovie-" & $getCurrentProcessId() & ".tmp"
    try:
      writeFile(scratch, data)
      moveFile(scratch, outPath)
    except CatchableError:
      removeFile(scratch)
      raise
    spans.len

proc movieCreationDate*(path: string): tuple[moment: DateTime; found: bool] =
  ## The presentation's creation time, from `mvhd`.
  ##
  ## `found` is false where the file leaves it unset, which is a real state and
  ## not a failure: a muxer with no date to write puts zero there.
  ##
  ## Only the header boxes are read. A date sits in `mvhd`, a few hundred bytes
  ## in; reading the whole file for it costs the recording's entire length, and
  ## a catalogue scan asks this of every video it meets.
  let data = try: readMovieHeaderBytes(path)
             except CatchableError: return
  let moov = findBox(data.toOpenArrayByte(0, data.high), 0, data.len, ["moov"])
  if moov.body < 0: return
  let mvhd = findBox(data.toOpenArrayByte(0, data.high), moov.body,
      moov.bodyEnd,
    ["mvhd"])
  if mvhd.body < 0: return
  let span = creationField(data, mvhd.body, mvhd.bodyEnd)
  if span.isNone: return
  let stamp = readCreation(data, span.get())
  if stamp <= 0: return
  (fromQuickTime(stamp), true)


