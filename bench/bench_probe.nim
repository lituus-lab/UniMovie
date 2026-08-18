# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## What a probe costs, against spawning ffprobe for the same answer.
##
## The comparison is the point of the library: a media catalogue probing a
## thousand files pays the process spawn a thousand times, and that cost is
## what reading the header in process removes. Both sides are asked the same
## question — dimensions, duration, codec — so the numbers are comparable.
##
## Every timed result feeds a non-inline sink printed at the end. Without it a
## release build is free to notice a result is never read and delete the call,
## which would read as an implausibly fast probe rather than a missing one.

import std/[os, osproc, strutils, monotimes, times, strformat, algorithm]
# Qualified only: importing it plainly makes `readMovieFile` ambiguous with
# the dispatching one, which is why the umbrella leaves this one out.
from UniMovie/isobmff import nil
import UniMovie

var sink = 0
proc consume(value: int) {.noinline.} =
  ## Where every timed result goes, so none of them is dead.
  ##
  ## Non-inline on purpose: a release build that can see the result is never
  ## read is free to delete the call that produced it, and a deleted probe
  ## reads as an implausibly fast one rather than as a missing measurement.
  sink += value

const Fixtures = ["tiny.mp4", "av.mp4", "rotated.mov", "tiny.mkv", "tiny.webm",
                  "tiny.avi", "tiny.ts", "tiny.ogv"]

proc fixturePath(name: string): string =
  ## A shipped fixture, by name, relative to the repository root — which is
  ## where `main` refuses to run from anywhere else.
  "tests" / "fixtures" / name

proc median(values: var seq[float]): float =
  ## The middle of `values`, averaging the two middle ones when the count is
  ## even. Sorts in place, which is why the parameter is `var`.
  ##
  ## A median rather than a mean: one round descheduled behind another process
  ## moves a mean and leaves a median where it was.
  values.sort()
  if values.len == 0: 0.0
  elif values.len mod 2 == 1: values[values.len div 2]
  else: (values[values.len div 2 - 1] + values[values.len div 2]) / 2.0

proc timeInProcess(path: string; rounds: int): float =
  ## Microseconds per probe, median of `rounds`.
  var samples = newSeq[float](rounds)
  for index in 0 ..< rounds:
    let start = getMonoTime()
    let movie = readMovieFile(path)
    let elapsed = float((getMonoTime() - start).inNanoseconds) / 1e9
    consume(movie.tracks.len + movie.tracks[0].width)
    samples[index] = elapsed * 1e6
  median(samples)

proc timeFfprobe(path: string; rounds: int): float =
  ## Microseconds per `ffprobe` invocation, median of `rounds`.
  var samples = newSeq[float](rounds)
  for index in 0 ..< rounds:
    let start = getMonoTime()
    let (output, code) = execCmdEx("ffprobe -v error -select_streams v:0 " &
      "-show_entries stream=width,height,codec_name:format=duration " &
      "-of default=nw=1 " & path.quoteShell)
    let elapsed = float((getMonoTime() - start).inNanoseconds) / 1e9
    consume(if code == 0: output.len else: 0)
    samples[index] = elapsed * 1e6
  median(samples)

proc timeWholeFile(path: string; rounds: int): float =
  ## Microseconds to read the same file by swallowing it whole, which is what
  ## the bounded walk replaces. The gap is the whole point and it grows with
  ## the file: on a few kilobytes of fixture it is noise, on a recording it is
  ## the difference between reading a header and reading the media.
  var samples = newSeq[float](rounds)
  for index in 0 ..< rounds:
    let start = getMonoTime()
    let movie = isobmff.readMovie(readFile(path))
    let elapsed = float((getMonoTime() - start).inNanoseconds) / 1e9
    consume(movie.tracks.len)
    samples[index] = elapsed * 1e6
  median(samples)

proc main() =
  ## Print the comparison as a markdown table, which `export_readme` splices
  ## into the README. Extra command-line arguments are treated as ISO base
  ## media files to time whole-file reading against, and reported separately.
  if not fileExists(fixturePath(Fixtures[0])):
    echo "run from the repository root: the fixtures are read by relative path"
    quit(1)
  let haveFfprobe = findExe("ffprobe").len > 0

  # Untimed rounds before anything is measured, so a cold file cache, a page
  # fault or a lazily bound symbol does not land on whichever container
  # happens to be measured first. One round per file was enough while this
  # measured CPU time; wall clock sees the first-touch cost too, and it landed
  # entirely on the first fixture — a fifty-microsecond mp4 beside two
  # eighteen-microsecond ones read as a slow container rather than as a cold
  # start.
  for _ in 0 ..< 20:
    for name in Fixtures:
      consume(readMovieFile(fixturePath(name)).tracks.len)

  echo "| file | container | in process | ffprobe | ratio |"
  echo "| --- | --- | ---: | ---: | ---: |"
  var totalMine = 0.0
  var totalTheirs = 0.0
  for name in Fixtures:
    let path = fixturePath(name)
    let mine = timeInProcess(path, 200)
    totalMine += mine
    var theirs = 0.0
    if haveFfprobe:
      theirs = timeFfprobe(path, 5)
      totalTheirs += theirs
    let container = $sniffFile(path)
    if haveFfprobe:
      echo &"| {name} | {container} | {mine:.1f} us | {theirs / 1000.0:.1f} ms | " &
           &"{int(theirs / mine)}x |"
    else:
      echo &"| {name} | {container} | {mine:.1f} us | - | - |"
  if haveFfprobe:
    echo ""
    echo &"Over the eight fixtures: {int(totalMine)} us in process, " &
         &"{int(totalTheirs / 1000.0)} ms through ffprobe."
  else:
    echo ""
    echo "ffprobe is not installed, so only the in-process column is real."
  # An ISO base media file given on the command line, where the two reading
  # strategies can actually be told apart. Nothing is shipped for this: a file
  # large enough to show the difference has no business in a repository.
  var extra: seq[string]
  for index in 1 .. paramCount(): extra.add paramStr(index)
  if extra.len > 0:
    echo ""
    echo "| file | size | whole file | header only | ratio |"
    echo "| --- | ---: | ---: | ---: | ---: |"
    for path in extra:
      if not fileExists(path):
        echo &"| {path.extractFilename} | missing | - | - | - |"
        continue
      if sniffFile(path) != cIsoBmff:
        echo &"| {path.extractFilename} | - | not ISO base media | - | - |"
        continue
      # Rounded to an integer rather than formatted with `:.0f`, which leaves
      # a trailing dot.
      let megabytes = int(float(getFileSize(path)) / 1_048_576.0 + 0.5)
      let whole = timeWholeFile(path, 5)
      let bounded = timeInProcess(path, 5)
      echo &"| {path.extractFilename} | {megabytes} MB | " &
           &"{whole / 1000.0:.1f} ms | {bounded / 1000.0:.3f} ms | " &
           &"{int(whole / max(bounded, 1e-9))}x |"
  echo ""
  echo &"(sink {sink})"

main()
