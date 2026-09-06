# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# UniMovie — demultiplexing for video containers.

version       = "0.1.0"
author        = "lituus-lab"
description   = "Reference template for the lituus-lab Uni* libraries (Nim + C-ABI + Python)"
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "https://github.com/lbartoletti/NimContracts#main"
# The ISOBMFF box layer, so the family has one box reader rather than two.
requires "https://github.com/lituus-lab/UniContainer#main"
# Native float mathematics: the family takes its maths from one place.
requires "https://github.com/lituus-lab/UniMath#main"

# nimble 0.22 exits 0 even when an `exec` inside a task fails, so a task's exit
# code says nothing about whether its body ran. Each task writes a marker as
# its last statement; `tools/gate.nim` removes the marker, runs the task, and
# fails if it is not there afterwards. `nimble canary` proves the gate still
# bites -- if `build/unigate canary` ever passes, every other green result is
# worthless. `nimble canary` on its own proves nothing: exiting 0 on a failed
# task is the very behaviour the gate exists to catch.
const gateExe =
  when defined(windows): "build/unigate.exe" else: "build/unigate"

template done(task: string) =
  mkDir "build/.gate"
  writeFile("build/.gate/" & task & ".ok", "")

proc gate(task: string): string =
  ## `exec gate("test")` -- builds the tool only when it is missing, and that is
  ## deliberate. Every call here happens inside a task the gate binary is
  ## already running, and Windows locks a running executable against being
  ## overwritten: rebuilding from here fails the job outright. Freshness is
  ## enforced where the gate is invoked instead -- CI compiles it at the start
  ## of every job, and tools/hooks/gated.sh rebuilds it when the source is
  ## newer.
  if not fileExists(gateExe):
    exec "nim c --hints:off -o:" & gateExe & " tools/gate.nim"
  gateExe & " " & task

task canary, "Must fail: proves the gate still catches a broken build":
  # No `done` here on purpose: the exec below raises, so the marker is never
  # written and the gate reports the failure nimble swallowed.
  exec "nim c -r --hints:off --path:src -o:build/canary tests/canary_broken.nim"


task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"
  done "lint"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"
  done "checkVGraph"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"
  done "docsDeps"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"
  done "book"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniMovie.nim"
  exec gate("book")
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"
  done "docs"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_isobmff tests/test_isobmff.nim"
  exec "nim c -r --path:src -o:build/test_probe tests/test_probe.nim"
  exec "nim c -r --path:src -o:build/test_mux tests/test_mux.nim"
  exec "nim c -r --path:src -o:build/test_samples tests/test_samples.nim"
  exec "nim c -r --path:src -o:build/test_edit tests/test_edit.nim"
  exec "nim c -r --path:src -o:build/test_fragment tests/test_fragment.nim"
  exec "nim c -r --path:src -o:build/test_mkvmux tests/test_mkvmux.nim"
  exec "nim c -r --path:src -o:build/test_lacing tests/test_lacing.nim"
  done "test"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_isobmff_rel tests/test_isobmff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_probe_rel tests/test_probe.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mux_rel tests/test_mux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_samples_rel tests/test_samples.nim"
  exec "nim c -r -d:release --path:src -o:build/test_edit_rel tests/test_edit.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fragment_rel tests/test_fragment.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mkvmux_rel tests/test_mkvmux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_lacing_rel tests/test_lacing.nim"
  done "testRelease"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_isobmff tests/test_isobmff.nim"
  exec "nim c -r --path:src -o:build/test_probe tests/test_probe.nim"
  exec "nim c -r --path:src -o:build/test_mux tests/test_mux.nim"
  exec "nim c -r --path:src -o:build/test_samples tests/test_samples.nim"
  exec "nim c -r --path:src -o:build/test_edit tests/test_edit.nim"
  exec "nim c -r --path:src -o:build/test_fragment tests/test_fragment.nim"
  exec "nim c -r --path:src -o:build/test_mkvmux tests/test_mkvmux.nim"
  exec "nim c -r --path:src -o:build/test_lacing tests/test_lacing.nim"
  done "testCi"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_isobmff_rel tests/test_isobmff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_probe_rel tests/test_probe.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mux_rel tests/test_mux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_samples_rel tests/test_samples.nim"
  exec "nim c -r -d:release --path:src -o:build/test_edit_rel tests/test_edit.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fragment_rel tests/test_fragment.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mkvmux_rel tests/test_mkvmux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_lacing_rel tests/test_lacing.nim"
  done "testCiRelease"

task testAll, "debug + release + C ABI":
  exec gate("test")
  exec gate("testRelease")
  exec gate("ctest")
  done "testAll"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"
  done "example"

# Nim takes `-o:` literally and appends no platform extension.
const
  sharedLib =
    when defined(windows): "libUniMovie.dll"
    elif defined(macosx): "libUniMovie.dylib"
    else: "libUniMovie.so"
  staticLib = "libUniMovie.a"  # MinGW `ar` on Windows, so `.a` everywhere.

  # @rpath install_name, so the copy bundled in the wheel is found at import.
  macArgs =
    when defined(macosx): " --passL:\"-Wl,-install_name,@rpath/" & sharedLib & "\""
    else: ""

task clib, "C shared library":
  exec "nim c --app:lib --noMain --mm:arc -d:release -o:" & sharedLib & macArgs &
       " src/UniMovie/c_api.nim"
  done "clib"

task clibStatic, "C static library":
  exec "nim c --app:staticlib --noMain --mm:arc -d:release -d:staticNoAutoInit -o:" & staticLib &
       " src/UniMovie/c_api.nim"
  done "clibStatic"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib --noMain --mm:arc -d:release -d:staticNoAutoInit" &
       " -o:UniMovie.lib src/UniMovie/c_api.nim"
  done "clibMsvc"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec gate("clibStatic")
  exec makeExe & " -C tests/c"
  done "ctest"

task cexample, "C demo":
  exec gate("clibStatic")
  exec makeExe & " -C examples/c"
  done "cexample"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"
  done "pyDeps"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec gate("clibMsvc")
  else:
    exec gate("clib")
  done "pyLib"

task buildCython, "Cython extension in-place":
  exec gate("pyLib")
  exec gate("pyDeps")
  # withDir, not `cd py && ...`: nimble's exec runs no shell on Windows, so
  # the `cd` and the `&&` reach the process as part of the command itself.
  withDir "py":
    exec "python3 setup.py build_ext --inplace"
  done "buildCython"

task pyTest, "Cython extension + pytest":
  exec gate("buildCython")
  withDir "py":
    exec "python3 -m pytest -q"
  done "pyTest"

task pyWheel, "wheel":
  exec gate("pyLib")
  exec gate("pyDeps")
  withDir "py":
    exec "python3 setup.py bdist_wheel"
  done "pyWheel"

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out of the capture, where lcov 2.x aborts on Nim's
  # codegen.
  # `mismatch` is the one capture suppression, and it is not optional: lcov 2.x
  # checks its own end line for a function against gcov's, and Nim's generated
  # destructors disagree. Every other lcov error still fails the build.
  # One nimcache per suite, then merge: a shared cache lets the second run
  # clobber the first's counters, and the report then describes only the last
  # suite while looking complete.
  rmDir "coverage"
  rmFile "lcov.info"
  var traces: seq[string]
  for suite in ["isobmff", "probe", "mux", "samples", "edit", "fragment",
                "mkvmux", "lacing"]:
    let cache = "build/covcache_" & suite
    rmDir cache
    exec "nim c --path:src --nimcache:" & cache &
         " --debugger:native --passC:--coverage --passL:--coverage" &
         " -o:build/test_cov_" & suite & " tests/test_" & suite & ".nim"
    exec "./build/test_cov_" & suite
    let trace = "build/lcov_" & suite & ".info"
    exec "lcov --capture --directory " & cache & " --base-directory ." &
         " --include \"*/src/UniMovie/*\" --output-file " & trace &
         " --quiet --ignore-errors mismatch"
    traces.add trace
  var merge = "lcov"
  for trace in traces: merge &= " --add-tracefile " & trace
  exec merge & " --output-file lcov.info --quiet --ignore-errors mismatch"
  # gcov can attribute a final generated expression to EOF + 1, and that one
  # artefact answers to two names: lcov 2.0, the version ubuntu-latest installs,
  # calls it `unmapped` and rejects `range` as a category outright, while 2.5
  # calls it `range` and can filter those lines away. Ask which one is there.
  let genhtmlRange =
    if gorgeEx("genhtml --version").output.contains("LCOV version 2.0"):
      " --ignore-errors unmapped"
    else: " --filter range --ignore-errors range"
  exec "genhtml lcov.info" & genhtmlRange &
       " --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
  done "coverage"

# Anything after `--` reaches the benchmark, not nimble: a task whose `exec` is
# a fixed string drops it silently, which makes a documented recipe write
# nothing at all.
proc forwardedArgs(): string =
  var seen = false
  for index in 0 .. paramCount():
    let argument = paramStr(index)
    # Quoted here rather than by `quoteShell`, which NimScript does not have.
    if seen: result &= " \"" & argument & "\""
    elif argument == "bench": seen = true

task bench, "Probe timings against ffprobe (release; not in the default gate)":
  exec "nim c -r -d:release --path:src --hints:off -o:build/bench" &
       " bench/bench_probe.nim" & forwardedArgs()
  done "bench"

task benchReadme, "Run the benchmarks and splice their output into bench/README.md":
  exec "nim c -r --path:src --hints:off -o:build/bench_readme bench/export_readme.nim"
  done "benchReadme"
