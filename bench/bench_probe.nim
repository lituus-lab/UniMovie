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

import std/[os, osproc, strutils, times, strformat, algorithm]
import UniMovie

var sink = 0
proc consume(value: int) {.noinline.} = sink += value

const Fixtures = ["tiny.mp4", "av.mp4", "rotated.mov", "tiny.mkv", "tiny.webm",
                  "tiny.avi", "tiny.ts", "tiny.ogv"]

proc fixturePath(name: string): string = "tests" / "fixtures" / name

proc median(values: var seq[float]): float =
  values.sort()
  if values.len == 0: 0.0
  elif values.len mod 2 == 1: values[values.len div 2]
  else: (values[values.len div 2 - 1] + values[values.len div 2]) / 2.0

proc timeInProcess(path: string; rounds: int): float =
  ## Microseconds per probe, median of `rounds`.
  var samples = newSeq[float](rounds)
  for index in 0 ..< rounds:
    let start = cpuTime()
    let movie = readMovieFile(path)
    let elapsed = cpuTime() - start
    consume(movie.tracks.len + movie.tracks[0].width)
    samples[index] = elapsed * 1e6
  median(samples)

proc timeFfprobe(path: string; rounds: int): float =
  ## Microseconds per `ffprobe` invocation, median of `rounds`. Wall clock, not
  ## CPU time: the cost being measured is a process spawn, most of which is not
  ## this process's own CPU.
  var samples = newSeq[float](rounds)
  for index in 0 ..< rounds:
    let start = epochTime()
    let (output, code) = execCmdEx("ffprobe -v error -select_streams v:0 " &
      "-show_entries stream=width,height,codec_name:format=duration " &
      "-of default=nw=1 " & path.quoteShell)
    let elapsed = epochTime() - start
    consume(if code == 0: output.len else: 0)
    samples[index] = elapsed * 1e6
  median(samples)

proc main() =
  if not fileExists(fixturePath(Fixtures[0])):
    echo "run from the repository root: the fixtures are read by relative path"
    quit(1)
  let haveFfprobe = findExe("ffprobe").len > 0

  # One untimed round per file, so a cold file cache does not land on whichever
  # container happens to be measured first.
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
  echo ""
  echo &"(sink {sink})"

main()
