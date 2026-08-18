<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniMovie

Demultiplexing for video containers: tracks, timescales, durations, pixel
dimensions, display rotation, keyframe indices, and the coded bytes of any one
sample. Nim, with a C ABI and a Python binding like every other engine in the
family.

It answers what `ffprobe` answers, in process.

## No decoder, by design

A track reports the four-character code its samples are in — `avc1`, `hvc1`,
`av01` — and hands over their bytes unchanged. Turning those into pixels
belongs to a backend the application registers, so neither this library nor
anything consuming it carries or distributes a patented decoder. On macOS that
backend is VideoToolbox, on Windows Media Foundation, elsewhere an `ffmpeg` the
user installed.

Codecs that are free of royalties — AV1, VP8/VP9, Theora, MPEG-2, Motion JPEG —
may be decoded here without that reservation.

| Container | Read | Limitations |
|---|:---:|---|
| MP4, M4V, MOV | yes | Tracks, timescales, durations, dimensions, rotation, sync-sample index, per-sample bytes. Fragmented files (`moof`) are not read: their samples live in tables this build does not walk. |
| Matroska, WebM | no | |
| AVI | no | |

## Rotation counts clockwise

`ffprobe` reports the same transformation matrix counting anticlockwise, so a
file it calls `rotation=90` reads here as 270 degrees. Both describe the same
matrix; anything migrating off `ffprobe` has to negate.

## Layout

```
src/UniMovie.nim            umbrella module
src/UniMovie/types.nim      what a demuxer reports, and the ceilings
src/UniMovie/isobmff.nim    MP4/MOV boxes, tracks, sample tables, keyframes
src/UniMovie/c_api.nim      C ABI (umov_)
include/UniMovie.h          hand-written C header
tests/ tests/c/             Nim and C ABI tests
examples/                   Nim + C demos
py/                         Cython binding + pytest
ADRs/                       0001 DAG, 0002 licence, 0003 C ABI, 0004 conventions
```

## How it is checked

Against `ffprobe`, never against itself: the fixtures come from `ffmpeg`, and
every shape the suite asserts is compared with what `ffprobe` reports for the
same file. Where `ffprobe` is not installed those comparisons are skipped and
the rest of the suite still runs, so such a machine tests less.

## Build

```bash
nimble install -y
nimble test           # Nim, debug (contracts active)
nimble testRelease    # Nim, release (contracts compiled away)
nimble testAll        # debug + release + C ABI
nimble ctest          # C ABI: static lib + tests/c
nimble cexample       # C demo
nimble example        # Nim demo
nimble pyTest         # Cython + pytest
nimble coverage       # gcov + lcov -> coverage/
nimble book           # nimib book -> book/index.html
nimble docs           # book + API reference -> pages/
```

## CI

`test`, `cabi` and `python` on ubuntu/macOS/Windows. `consume-cabi` and
`consume-wheel` rebuild against the published artifacts on a machine without Nim,
so what ships is what was tested. `coverage` and `docs` run on ubuntu.

`dco` blocks PRs missing a `Signed-off-by` trailer; `commitizen` blocks PRs whose
commits or title are not [Conventional Commits](https://www.conventionalcommits.org/)
(`CONTRIBUTING.md`).

The same gates run locally with pre-commit: `pip install pre-commit && pre-commit install`
(`CONTRIBUTING.md`).

`docs` publishes to GitHub Pages only from a public repo — the template itself is
private, so that deploy stays skipped here and turns itself on in the engines.

## Clone map

Cloned from UniTemplate: the family scaffold, with its tasks, CI matrix, ADRs
and the C ABI + Python conventions already in place.

| Template | Clone | Example |
|---|---|---|
| `UniMovie` | `UniFoo` | `UniAccurate`, `UniMath`, `UniGeom` |
| `unimovie` | `unifoo` | `uniaccurate`, `unimath`, `unigeom` |
| `ut_` | `<short>_` | `ua_`, `um_`, `ulin_`, `ug_` |
| `libUniMovie` | `libUniFoo` | `libUniMusic` |
| `UniMovie.h` | `UniFoo.h` | `UniMusic.h` |

Files to rename: `UniMovie.nimble`, `src/UniMovie.nim`, `src/UniMovie/`,
`include/UniMovie.h`, `tests/c/test_unimovie.c` (+ its Makefile target),
`py/unimovie/`. Then update `LICENSE`/`NOTICE` copyright and the ADR titles.

## AI-assisted contributions

Assistance from AI/LLM tools is welcome on the same terms as any other
contribution.

- **Accountability.** The human contributor is the author and remains fully
  responsible for the change. The DCO sign-off (`Signed-off-by`) is the mechanism:
  by signing you certify the content is yours or properly licensed — this covers
  AI-assisted work, provided you can stand behind it.
- **No third-party contamination.** Ensure AI output introduces no code from a
  third party without a compatible license and attribution. If an LLM reproduced
  protected material, do not submit it.
- **Correctness is yours.** The gates (tests, `nimble lint`, conventional commits,
  pre-commit) catch a lot, but you own the result — review and verify what you
  commit.
- **Atomic commits.** Each commit is one logical change. A PR may stack
  several atomic commits (one per element, say) — one monolithic big-bang
  commit is not.
- **Disclosure.** State in the PR whether AI assistance was used (see the PR
  template). It is not a hard requirement — the DCO remains the gate.

## License

Apache-2.0 (`LICENSE`). DCO sign-off on every commit (`CONTRIBUTING.md`).
