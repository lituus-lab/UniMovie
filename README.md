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

| Container | Limitations |
|---|---|
| MP4, M4V, MOV, 3GP | Tracks, timescales, durations, dimensions, rotation, sync-sample index, and the coded bytes of any sample. Fragmented files (`moof`) are not read: their samples live in tables this build does not walk. |
| Matroska, WebM | Doc type, timescale, duration, tracks, codecs and dimensions from the header elements. Clusters are not walked, so there is no per-sample access and no keyframe index — Cues would give one. |
| AVI | Streams, codecs, dimensions, frame count and duration from `hdrl`. AVI has no sync-sample table; a keyframe index would have to come from the per-chunk flags in `movi`. |
| MPEG-TS, M2TS, MTS | Streams and codecs from the program tables, duration from the span of the presentation timestamps. The format carries no dimensions, so an H.264 one is read from the sequence parameter set — see below. The three packet sizes are told apart by the spacing of the sync bytes, not by the extension. |
| Ogg (OGV) | Streams and codecs from each one's first packet, with the picture size and frame rate the identification header carries. Duration is the frame count over that rate. VP8 is covered by a fixture; the Theora path is written from the specification, because no encoder here produces one. |

`sampleCount` of 0 and an empty `keyframes` mean *not reported for this
container*, never *empty*: only ISO base media carries a sync-sample table, and
only it and AVI and Ogg count samples at all. A caller testing for an empty file
should look at the duration.

`sampleCount` of 0 and an empty `keyframes` mean *not reported for this
container*, never *empty*: only ISO base media carries a sync-sample table, and
only it, AVI and Ogg count samples at all. A caller testing whether a file holds
anything should look at the duration.

Codec identifiers are reported as the four-character codes MP4 uses, whichever
container they came from: a Matroska `V_MPEG4/ISO/AVC` reads as `avc1`, so a
caller registers one backend per codec rather than one per container. An
identifier with no MP4 equivalent passes through unchanged.

## One place it looks inside a stream

A transport stream carries no dimensions — they live in the coded stream — so a
picture size for H.264 comes from the sequence parameter set. Reading a
parameter set produces no pixel and is not decoding; `ffprobe` reaches those
numbers the same way. It is the only place this library looks past a container,
and it does so for that one codec.

## Rotation counts clockwise

`ffprobe` reports the same transformation matrix counting anticlockwise, so a
file it calls `rotation=90` reads here as 270 degrees. Both describe the same
matrix; anything migrating off `ffprobe` has to negate.

## What's inside

- **What a demuxer reports** — `src/UniMovie/types.nim`. One shape every
  container reader produces: tracks with a kind, a codec, a timescale, a
  duration, and — for video — dimensions, rotation and a keyframe index.
- **ISO base media** — `src/UniMovie/isobmff.nim`. MP4, MOV, M4V and 3GP,
  including the sample tables that give per-sample access.
- **EBML** — `src/UniMovie/matroska.nim`. Matroska and WebM, which are one
  format under two doc types.
- **RIFF** — `src/UniMovie/avi.nim`. AVI, little-endian, from 1992.
- **Transport streams** — `src/UniMovie/mpegts.nim`. TS, M2TS and MTS, found by
  the rhythm of their sync bytes because the format has no magic number.
- **Ogg** — `src/UniMovie/ogg.nim`. Pages into logical streams, each identified
  by its first packet.
- **Dispatch** — `src/UniMovie/probe.nim` names a container from its bytes and
  reads it; `src/UniMovie/c_api.nim` is the same library in C.

## The Uni* family

UniMovie is a leaf of `lituus-lab`'s `Uni*` family: a set of Nim libraries,
each with a C ABI and a Python binding, unified by a shared dependency graph and
documentation and testing conventions. See
[lituus-lab/.github](https://github.com/lituus-lab/.github) for the family's
purpose and philosophy. It depends on `UniImage` alone, for the ISOBMFF box
reader: HEIF and MP4 are the same box structure, and the family reads it in one
place rather than two. Nothing else — demultiplexing is byte handling, and a
consumer cataloguing a media library should not link a numeric stack to read a
header.

## Provenance & development

Written from the published formats: ISO 14496-12 for ISO base media, the
Matroska specification, ISO 13818-1 for transport streams, RFC 3533 for Ogg,
and the Windows `BITMAPINFOHEADER` layout for AVI. No code is ported from
another implementation, and `NOTICE` records the one bundled dependency.

Development used LLM/agent assistance extensively, on the terms described
below. The git history is short and linear as a result; the formats it reads
have been stable for decades.

## Benchmarks

`nimble bench` measures what a probe costs against spawning `ffprobe` for the
same answer; it is not part of the gate. `nimble benchReadme` runs it and writes
the numbers into [bench/README.md](bench/README.md), tagged by machine, so
nothing there is retyped by hand.

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
