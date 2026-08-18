# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Runs the benchmark and splices its real output into `bench/README.md`.
##
## Each machine keeps its own block between a tagged pair of comments, so a
## second machine appends alongside the first rather than overwriting it. The
## numbers are never typed by hand: this reads what the run printed.

import std/[os, osproc, strutils, strformat]

const
  Readme = "bench" / "README.md"
  Insert = "<!-- bench:insert -->"

proc machineSlug(): string =
  ## A label for the machine the numbers came from. Overridable, because
  ## auto-detection is not always the name worth recording.
  result = getEnv("UNIMOVIE_BENCH_MACHINE")
  if result.len > 0: return
  var cpu = ""
  when defined(macosx):
    let (brand, code) = execCmdEx("sysctl -n machdep.cpu.brand_string")
    if code == 0: cpu = brand.strip()
  elif defined(linux):
    if fileExists("/proc/cpuinfo"):
      for line in readFile("/proc/cpuinfo").splitLines():
        if line.startsWith("model name"):
          cpu = line.split(":", 1)[1].strip()
          break
  if cpu.len == 0: cpu = hostCPU
  result = (hostOS & "-" & cpu).toLowerAscii().multiReplace(
    ("(r)", ""), ("(tm)", ""), (" ", "-"), (".", ""), ("@", ""), ("--", "-"))

proc main() =
  ## Run the benchmark and splice its table between the README's markers,
  ## leaving the rest of the file untouched. Rewrites in place; run it from
  ## the repository root.
  if not fileExists(Readme):
    quit(&"run from the repository root: {Readme} is not here", 1)
  let (output, code) = execCmdEx("nim c -r -d:release --path:src --hints:off " &
    "-o:build/bench bench/bench_probe.nim")
  if code != 0:
    echo output
    quit("the benchmark did not run", 1)
  # Keep only the table and the summary; the compiler's own lines are not data.
  var body: seq[string]
  for line in output.splitLines():
    if line.startsWith("|") or line.startsWith("Over the eight") or
       line.startsWith("ffprobe is not"):
      body.add line
    elif body.len > 0 and line.strip().len == 0:
      body.add ""
  let slug = machineSlug()
  let open = &"<!-- bench:machine={slug} -->"
  let close = &"<!-- /bench:machine={slug} -->"
  let entry = open & "\n\n" & body.join("\n").strip() & "\n\n" & close

  var readme = readFile(Readme)
  let start = readme.find(open)
  if start >= 0:
    let stop = readme.find(close, start)
    if stop < 0: quit(&"{Readme}: {open} has no closing tag", 1)
    readme = readme[0 ..< start] & entry & readme[stop + close.len .. ^1]
  else:
    let anchor = readme.find(Insert)
    if anchor < 0: quit(&"{Readme}: no {Insert} anchor", 1)
    readme = readme[0 ..< anchor + Insert.len] & "\n\n" & entry &
             readme[anchor + Insert.len .. ^1]
  writeFile(Readme, readme)
  echo output
  echo &"spliced into {Readme} under {slug}"

main()
