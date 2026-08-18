<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0004: UniMovie conventions

- Status: Accepted
- Date: 2026-08-18
- Scope: UniMovie

## Layout

```
UniMovie.nimble             package + tasks
config.nims                 build config
src/UniMovie.nim            umbrella, re-exports every public submodule
src/UniMovie/types.nim      what a demuxer reports, and the ceilings
src/UniMovie/isobmff.nim    MP4, MOV, M4V, 3GP
src/UniMovie/matroska.nim   Matroska and WebM
src/UniMovie/avi.nim        AVI
src/UniMovie/mpegts.nim     MPEG-TS, M2TS, MTS
src/UniMovie/ogg.nim        Ogg
src/UniMovie/probe.nim      one entry point over every container
src/UniMovie/c_api.nim      C ABI
include/UniMovie.h          hand-written C header
tests/ tests/c/             Nim and C ABI tests
tests/fixtures/             one small file per container, made by ffmpeg
examples/                   Nim + C demos
py/                         Cython binding + pytest + notebook
book/index.nim              nimib book, compiled at docs build
ADRs/                       0001 layers, 0002 licence, 0003 C ABI, 0004 conventions
LICENSE NOTICE CONTRIBUTING.md SECURITY.md .gitignore README.md AGENTS.md CLAUDE.md
```

## Naming

- Nim package and umbrella module: `UniMovie`.
- C library `libUniMovie`, header `UniMovie.h`, symbol prefix `umov_`.
- Python package `unimovie`.

## Conventions

- Every routine carries a docstring, private ones included: what it does, and
  the non-obvious constraint a reader would otherwise have to derive.
- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. A precondition states what a correct caller must not do;
  anything derived from a file — a timescale, a track count, a box length — is
  checked in the `body:` and raises `MovieError`, because a precondition
  disappears in release and would leave a release build dividing by zero in
  silence. A postcondition that restates the body earns nothing and is left out.
- Out-of-range input at the C ABI is rejected with `UMOV_ERR_ARG`, never
  clamped into range.
- English comments, terse, describing what is done.
- Every module under `src/` ends with two blank lines, and more where the
  compiler asks: `genhtml` refuses coverage data pointing past a file's last
  line, so `nimble coverage` fails on a source that stops too soon. `nimble
  lint` checks it.
- Maths comes from `UniMath`, never from `std/math` — no module here needs any
  yet, and one that does takes it from there.
- A container reader never imports a sibling reader; `probe` is the only module
  that knows more than one format exists.

## Verification

A reader is checked against `ffprobe`, which is what it replaces and shares no
code with it. Every shape a test asserts — dimensions, duration, codec, track
kind — is compared with what `ffprobe` reports for the same file. Where
`ffprobe` is absent those comparisons are skipped and the rest still runs, so
such a machine tests less.

Fixtures come from `ffmpeg` and are a few kilobytes each. They are chosen for
the container shapes they contain — a rotated track, a file with no audio, one
with a sync table and one without — not for how they look.

## CI gates

- `nimble testCi` + `testCiRelease` on ubuntu/macOS/Windows.
- `nimble ctest` on linux/macOS.
- `nimble pyTest` on linux.
- `nimble lint`, `checkVGraph`, `coverage`, `docs` on ubuntu.
