# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Correcting an ISO base media file's creation date, checked against ffprobe.
##
## ffprobe shares no code with this writer, so it is the only honest oracle for
## whether a date was really written: a test that read the value back with this
## library's own reader would pass on a shared misunderstanding of the epoch.
##
## Every case works on a copy. A fixture a test rewrote would make the next run
## test something else.
import std/[unittest, os, osproc, strutils, times]
import UniMovie/edit

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc ffprobeCreation(path: string): string =
  ## What ffprobe reports as the container's creation time, or "" when ffprobe
  ## is absent or the file carries none.
  if findExe("ffprobe").len == 0: return ""
  let (output, code) = execCmdEx("ffprobe -v error -show_entries " &
    "format_tags=creation_time -of default=nw=1:nk=1 " & path.quoteShell)
  if code != 0: return ""
  for line in output.splitLines():
    let value = line.strip()
    if value.len > 0: return value
  ""

proc ffprobeDecodes(path: string): bool =
  ## Whether ffprobe still finds a readable stream. An edit that moved a byte of
  ## the sample tables would leave a file that looks intact and plays nothing.
  if findExe("ffprobe").len == 0: return true
  let (output, code) = execCmdEx("ffprobe -v error -show_entries " &
    "stream=codec_name -of default=nw=1:nk=1 " & path.quoteShell)
  code == 0 and output.strip().len > 0

proc workingCopy(name, suffix: string): string =
  ## A copy under the temp directory, named for the test using it so two suites
  ## running at once cannot collide.
  result = getTempDir() / ("unimovie-edit-" & suffix & "-" &
    $getCurrentProcessId() & "-" & name)
  copyFile(Fixtures / name, result)

suite "correcting a wrong camera clock":
  test "the date ffprobe reads is the date that was written":
    let path = workingCopy("tiny.mp4", "written")
    defer: removeFile(path)
    let wanted = dateTime(2019, mAug, 14, 10, 30, 0, zone = utc())
    let changed = setMovieCreationDate(path, path, wanted)
    check changed >= 3 # mvhd, plus tkhd and mdhd for the one track
    let reported = ffprobeCreation(path)
    if reported.len > 0:
      check reported.startsWith("2019-08-14T10:30:00")
    check ffprobeDecodes(path)

  test "the samples are untouched, so the file is the same size":
    let path = workingCopy("av.mp4", "size")
    defer: removeFile(path)
    let before = getFileSize(path)
    discard setMovieCreationDate(path, path,
      dateTime(2001, mJan, 2, 3, 4, 5, zone = utc()))
    # A fixed-width field replaced in place: the stbl offsets into mdat stay
    # valid precisely because nothing moved.
    check getFileSize(path) == before
    check ffprobeDecodes(path)

  test "every track is corrected, not only the first":
    # av.mp4 carries sound as well as pictures, and ffprobe reads each stream's
    # own date. One left behind is how a player comes to disagree with a probe.
    let path = workingCopy("av.mp4", "tracks")
    defer: removeFile(path)
    let changed = setMovieCreationDate(path, path,
      dateTime(2015, mMar, 4, 5, 6, 7, zone = utc()))
    check changed >= 5 # mvhd + two tracks × (tkhd, mdhd)
    if findExe("ffprobe").len > 0:
      let (output, code) = execCmdEx("ffprobe -v error -show_entries " &
        "stream_tags=creation_time -of default=nw=1:nk=1 " & path.quoteShell)
      check code == 0
      var seen = 0
      for line in output.splitLines():
        if line.strip().len == 0: continue
        check line.strip().startsWith("2015-03-04T05:06:07")
        inc seen
      check seen >= 2

  test "reading it back gives what was written":
    let path = workingCopy("tiny.mp4", "roundtrip")
    defer: removeFile(path)
    let wanted = dateTime(2020, mDec, 25, 18, 0, 0, zone = utc())
    discard setMovieCreationDate(path, path, wanted)
    let read = movieCreationDate(path)
    check read.found
    check read.moment.format("yyyy-MM-dd HH:mm:ss") ==
      wanted.format("yyyy-MM-dd HH:mm:ss")

  test "the output may be a different file, leaving the input alone":
    let path = workingCopy("tiny.mp4", "copy")
    let dest = path & ".out"
    defer:
      removeFile(path)
      removeFile(dest)
    let before = movieCreationDate(path)
    discard setMovieCreationDate(path, dest,
      dateTime(1999, mJun, 1, 0, 0, 0, zone = utc()))
    let after = movieCreationDate(path)
    check after.found == before.found
    if before.found:
      check after.moment == before.moment
    check movieCreationDate(dest).moment.year == 1999

suite "what it refuses rather than half-doing":
  test "a file that is not ISO base media is named as such":
    let path = getTempDir() / ("unimovie-edit-notmp4-" & $getCurrentProcessId())
    writeFile(path, "this is not a movie")
    defer: removeFile(path)
    expect MovieDateError:
      discard setMovieCreationDate(path, path,
        dateTime(2020, mJan, 1, 0, 0, 0, zone = utc()))

  test "a date before the epoch is refused, not wrapped":
    let path = workingCopy("tiny.mp4", "old")
    defer: removeFile(path)
    expect MovieDateError:
      discard setMovieCreationDate(path, path,
        dateTime(1899, mJan, 1, 0, 0, 0, zone = utc()))

  test "the epoch conversion is QuickTime's, not Unix's":
    # 1904-01-01 is zero, and 1970-01-01 is the offset itself. Getting this
    # wrong is a 66-year error that still produces a plausible-looking date.
    check toQuickTime(dateTime(1970, mJan, 1, 0, 0, 0, zone = utc())) == Epoch1904
    check toQuickTime(dateTime(1904, mJan, 1, 0, 0, 0, zone = utc())) == 0
    check fromQuickTime(Epoch1904).year == 1970

