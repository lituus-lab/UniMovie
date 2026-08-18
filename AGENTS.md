<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# AGENTS.md — UniMovie

## Build & gates

```bash
nimble install -y
nimble testAll     # Nim debug + release + C ABI
nimble pyTest      # Cython + pytest (needs libUniMovie.so)
nimble ctest       # C ABI only
nimble example     # Nim demo
nimble cexample    # C demo
nimble lint
nimble checkVGraph
nimble coverage    # gcov + lcov -> coverage/ (needs lcov; linux/macOS)
nimble docs        # nimib book + API reference -> pages/ (needs nimib)
nimble bench       # in-process probe against spawning ffprobe
nimble benchReadme # bench, then splice its output into bench/README.md
```

`nimble docs` needs a complete Nim distribution: `--project` builds `dochack`,
which Homebrew's `nim` omits (no `tools/`). choosenim and the CI action ship it.

CI: 3-OS Nim matrix, C ABI on linux/macOS, Python on linux, plus lint,
checkVGraph, coverage and docs.

## Conventions

- **Every routine carries a docstring**, private ones included: what it does,
  and the non-obvious constraint a reader would otherwise have to derive.
- **NimContracts** `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled
  away under `-d:release`. A precondition states what a correct **caller** must
  not do. Anything derived from a file — a timescale, a track count, a box
  length — is checked in the `body:` and raises `MovieError`: a precondition
  disappears in release, so one guarding file-derived data would raise in debug
  and divide by zero in release, which is the worst of both. A postcondition
  that restates the body earns nothing and is left out.
- **The C ABI never raises**: an entry point returns a status and puts the
  reason in `umov_last_error`. Out-of-range input is **rejected** with
  `UMOV_ERR_ARG`, never clamped into range.
- C ABI: hand-written `include/UniMovie.h` kept in sync with
  `src/UniMovie/c_api.nim`; `tests/c` links the header against the lib, so a
  renamed or retyped symbol fails to compile. Built
  `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`. `--noMain` means
  no module-level initialiser runs, so anything the ABI reaches must be a
  compile-time constant.
- C symbols carry the `umov_` prefix; lib `libUniMovie`; header `UniMovie.h`.
- **Maths comes from `UniMath`**, never `std/math`. No module here needs any
  yet; one that does takes it from there rather than reaching for the stdlib.
- A container reader never imports a sibling reader. `probe` is the only module
  that knows more than one format exists, which is what keeps one format's
  quirk out of another's parser.
- `book/index.nim` is nimib: its code blocks are compiled and run at docs
  build, so prose that outlives its API breaks the build. `nbSave` must be the
  last statement — anything after it renders as source instead of running.
  `py/notebooks/quickstart.ipynb` plays the same role for Python.
- End every module under `src/` with two blank lines, and more where the
  compiler asks for it: `genhtml` refuses coverage data pointing past a file's
  last line, so `nimble coverage` fails on a source that stops too soon and
  names the file and the line it wanted. `nimble lint` checks it.

## Verification

A reader is checked against **`ffprobe`**, which is what it replaces and which
shares no code with it. Every shape a test asserts — dimensions, duration,
codec, track kind — is compared with what `ffprobe` reports for the same file,
never with what this reader produced last time. Where `ffprobe` is absent those
comparisons are skipped and the rest of the suite still runs, so such a machine
tests less.

`ffprobe` prints an entry more than once for a transport stream, so the test
helper takes the first non-empty line rather than the whole output.

Fixtures come from `ffmpeg`, a few kilobytes each, chosen for the container
shapes they hold: a rotated track (`rotated.mov`), a file with sound and one
without (`av.mp4`, `tiny.mp4`), one with a sync table and one without, and one
per container family. Regenerate them with the commands in `tests/fixtures`'s
own history rather than by hand.

## Scope

Demultiplexing for video containers, and nothing else. No decoder and no system
API: a track reports the code its samples are in, and producing pixels belongs
to a backend the application registers. Which codecs may be decoded at all is
ADR-0002's subject.

The one place this library looks past a container is the H.264 sequence
parameter set, because a transport stream carries no dimensions and would
otherwise be unusable; that produces no pixel.
