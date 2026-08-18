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
requires "https://github.com/lituus-lab/UniImage#main"

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniMovie.nim"
  exec "nimble book"
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_isobmff tests/test_isobmff.nim"
  exec "nim c -r --path:src -o:build/test_probe tests/test_probe.nim"
  exec "nim c -r --path:src -o:build/test_mux tests/test_mux.nim"
  exec "nim c -r --path:src -o:build/test_samples tests/test_samples.nim"
  exec "nim c -r --path:src -o:build/test_edit tests/test_edit.nim"
  exec "nim c -r --path:src -o:build/test_fragment tests/test_fragment.nim"
  exec "nim c -r --path:src -o:build/test_mkvmux tests/test_mkvmux.nim"
  exec "nim c -r --path:src -o:build/test_lacing tests/test_lacing.nim"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_isobmff_rel tests/test_isobmff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_probe_rel tests/test_probe.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mux_rel tests/test_mux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_samples_rel tests/test_samples.nim"
  exec "nim c -r -d:release --path:src -o:build/test_edit_rel tests/test_edit.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fragment_rel tests/test_fragment.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mkvmux_rel tests/test_mkvmux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_lacing_rel tests/test_lacing.nim"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_isobmff tests/test_isobmff.nim"
  exec "nim c -r --path:src -o:build/test_probe tests/test_probe.nim"
  exec "nim c -r --path:src -o:build/test_mux tests/test_mux.nim"
  exec "nim c -r --path:src -o:build/test_samples tests/test_samples.nim"
  exec "nim c -r --path:src -o:build/test_fragment tests/test_fragment.nim"
  exec "nim c -r --path:src -o:build/test_mkvmux tests/test_mkvmux.nim"
  exec "nim c -r --path:src -o:build/test_lacing tests/test_lacing.nim"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_isobmff_rel tests/test_isobmff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_probe_rel tests/test_probe.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mux_rel tests/test_mux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_samples_rel tests/test_samples.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fragment_rel tests/test_fragment.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mkvmux_rel tests/test_mkvmux.nim"
  exec "nim c -r -d:release --path:src -o:build/test_lacing_rel tests/test_lacing.nim"

task testAll, "debug + release + C ABI":
  exec "nimble test"
  exec "nimble testRelease"
  exec "nimble ctest"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"

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

task clibStatic, "C static library":
  exec "nim c --app:staticlib --noMain --mm:arc -d:release -o:" & staticLib &
       " src/UniMovie/c_api.nim"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib --noMain --mm:arc -d:release" &
       " -o:UniMovie.lib src/UniMovie/c_api.nim"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec "nimble clibStatic"
  exec makeExe & " -C tests/c"

task cexample, "C demo":
  exec "nimble clibStatic"
  exec makeExe & " -C examples/c"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec "nimble clibMsvc"
  else:
    exec "nimble clib"

task buildCython, "Cython extension in-place":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  exec "cd py && python3 setup.py build_ext --inplace"

task pyTest, "Cython extension + pytest":
  exec "nimble buildCython"
  exec "cd py && python3 -m pytest -q"

task pyWheel, "wheel":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  exec "cd py && python3 setup.py bdist_wheel"

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out of the capture, where lcov 2.x aborts on Nim's
  # codegen. Together they leave nothing to suppress: no --ignore-errors here,
  # so a real problem still fails the build.
  # One nimcache per suite, then merge: a shared cache lets the second run
  # clobber the first's counters, and the report then describes only the last
  # suite while looking complete.
  rmDir "coverage"
  rmFile "lcov.info"
  var traces: seq[string]
  for suite in ["isobmff", "probe", "mux", "samples", "fragment", "mkvmux",
                "lacing"]:
    let cache = "build/covcache_" & suite
    rmDir cache
    exec "nim c --path:src --nimcache:" & cache &
         " --debugger:native --passC:--coverage --passL:--coverage" &
         " -o:build/test_cov_" & suite & " tests/test_" & suite & ".nim"
    exec "./build/test_cov_" & suite
    let trace = "build/lcov_" & suite & ".info"
    exec "lcov --capture --directory " & cache & " --base-directory ." &
         " --include \"*/src/UniMovie/*\" --output-file " & trace & " --quiet"
    traces.add trace
  var merge = "lcov"
  for trace in traces: merge &= " --add-tracefile " & trace
  exec merge & " --output-file lcov.info --quiet"
  exec "genhtml lcov.info --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"

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

task benchReadme, "Run the benchmarks and splice their output into bench/README.md":
  exec "nim c -r --path:src --hints:off -o:build/bench_readme bench/export_readme.nim"
