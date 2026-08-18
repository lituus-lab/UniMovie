# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Fails if nimpretty would reformat any source. Checks, never rewrites.
import std/[os, osproc, strformat, strutils]

const Roots = ["src", "tests", "examples", "book"]

proc sources(): seq[string] =
  ## Every `.nim` file under the roots that exist, in walk order. A root that
  ## is absent is skipped rather than reported: not every repository in the
  ## family carries a book or an example.
  for root in Roots:
    if dirExists(root):
      for path in walkDirRec(root):
        if path.endsWith(".nim"):
          result.add path

proc shortEndings(): seq[string] =
  ## Modules under `src/` that stop before the two blank lines the convention
  ## asks for.
  ##
  ## Not a matter of taste: Nim maps a trailing statement one line past the
  ## end of the file, and `genhtml` refuses coverage data pointing past a
  ## file's last line. A source that stops too soon fails `nimble coverage`
  ## instead, where the message names lcov rather than the file behind it.
  for path in walkDirRec("src"):
    if path.endsWith(".nim") and not readFile(path).endsWith("\n\n\n"):
      result.add path

proc main() =
  ## Format every source into a scratch tree and compare, then check that
  ## every module under `src/` ends as the convention requires. Exits non-zero
  ## and names the offending files; nothing under the working tree is
  ## rewritten, so running this can never be the thing that changes a source.
  let tmp = "build" / "lint"
  removeDir tmp

  let files = sources()
  var dirty: seq[string]
  for src in files:
    let formatted = tmp / src
    createDir formatted.parentDir
    if execCmd(&"nimpretty --out:{formatted.quoteShell} {src.quoteShell}") != 0:
      quit(&"lint: nimpretty failed on {src}", 1)
    if readFile(src) != readFile(formatted):
      dirty.add src

  if dirty.len > 0:
    echo "lint: nimpretty would reformat:"
    for src in dirty:
      echo "  ", src
    quit("lint: run nimpretty on the files above", 1)

  let short = shortEndings()
  if short.len > 0:
    echo "lint: these stop before the two blank lines a covered source needs:"
    for src in short:
      echo "  ", src
    quit("lint: add the missing blank lines to the files above", 1)
  echo &"lint: {files.len} files clean, endings included"

main()
