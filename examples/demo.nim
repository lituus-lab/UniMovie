# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Name a file and it says what is inside — through the public API only, with
## no knowledge of which container it turned out to be.
import std/[os, strformat]
import UniMovie

proc main() =
  ## Read the file named on the command line and print what its header says.
  ##
  ## Every failure is reported and exits non-zero except a missing argument,
  ## which prints the usage and exits clean: being run with no argument is a
  ## question, not an error.
  if paramCount() < 1:
    echo "usage: demo <video file>"
    quit(0)
  let path = paramStr(1)
  if path.len == 0:
    # Otherwise the failure below is reported against an empty name, which
    # reads as though the library lost the path rather than never having one.
    echo "usage: demo <video file>"
    quit(1)
  let movie = try: readMovieFile(path)
    except MovieError as error:
      echo &"{path}: {error.msg}"
      quit(1)
    except IOError as error:
      echo &"{path}: {error.msg}"
      quit(1)

  echo &"{path}: {movie.format}, {movie.durationSeconds:.3f} s, " &
       &"{movie.tracks.len} track(s)"
  for index, track in movie.tracks:
    var line = &"  [{index}] {track.kind} {track.codec}"
    if track.kind == tkVideo:
      line &= &" {track.width}x{track.height}"
      if track.rotation != rot0: line &= &" rotated {ord(track.rotation)} deg"
    line &= &", {track.sampleCount} samples, {track.keyframes.len} keyframes"
    echo line

main()
