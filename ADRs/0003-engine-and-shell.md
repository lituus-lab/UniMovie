<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0003: The C ABI, and what it must reach

- Status: Accepted
- Date: 2026-08-18
- Scope: UniMovie

## Decision

The library is pure Nim with a thin C ABI in `src/UniMovie/c_api.nim`, built
`--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`. `--mm:arc` gives a
foreign caller a deterministic memory model with no cycle collector; `--noMain`
means no `NimMain()` call is needed from C — and, in exchange, that no
module-level initialiser runs, so every table the ABI reaches has to be a
compile-time constant.

`include/UniMovie.h` is written by hand and kept level with `c_api.nim`.
`tests/c` links the header against the library, so a renamed or retyped symbol
fails to compile rather than at a caller's site.

No Nim exception crosses the boundary: every entry point returns a status and
puts the reason in `umov_last_error`. **Out-of-range input is rejected with
`UMOV_ERR_ARG`, never clamped into range** — a caller that passed nonsense is
told so rather than handed a file it did not ask for.

Python is Cython over the shared library, with an `$ORIGIN` rpath so the
bundled library travels inside the wheel.

## Completeness

The ABI covers the library's whole subject, not the parts a first consumer
happened to ask for. Fifteen entry points, all reachable from Python as well:

| capability | entry point |
|---|---|
| the library's version, and the reason for the last failure | `umov_version`, `umov_last_error` |
| container name, track count, first video and audio track, duration | `umov_probe` |
| one track's kind, codec, displayed size, rotation, sample and keyframe counts | `umov_track` |
| the size that track's decoder produces, which the displayed one is not | `umov_track_sizes` |
| the container, from the leading bytes and without reading further | `umov_sniff` |
| how many coded samples a track holds, and the bytes of any one | `umov_coded_sample_count`, `umov_coded_sample` |
| per-sample decode duration and composition offset | `umov_sample_timing` |
| a track's edit list | `umov_edit_list` |
| writing an MP4, a fragmented MP4, a Matroska or a WebM | `umov_writer_open`, `umov_writer_sample`, `umov_writer_flush`, `umov_writer_close` |
| what a writer has buffered and how many boundaries it has written | `umov_writer_counts` |

Two conventions hold across the additions. An array or a buffer takes **two
calls**, the first with a null pointer to learn the size — no allocation
crosses the boundary in either direction, so there is no ownership to agree on.
And a **writer is a handle, not a pointer**, valid on the thread that opened it;
zero is never one, so a zeroed struct cannot be mistaken for an open file.

## What stays Nim-side

These are reachable from Nim only, because the ABI covers what they are for by
a better route:

- **Per-container readers and sample access** — `readMovie`, `codedSample` and
  `codedSampleCount` on each of `isobmff`, `matroska`, `avi`, `mpegts`, `ogg`,
  and the named entry points behind them: `readAvi`/`readAviFile`,
  `readMatroska`/`readMatroskaFile`, `readMpegTs`/`readMpegTsFile`,
  `readOgg`/`readOggFile`, together with `isMpegTs`. The ABI dispatches on the
  file's own bytes; a C caller naming a format it guessed from an extension
  would be choosing worse information over better.
- **`readMovieHeaderFile`** and **`readMovieHeaderBytes`** — the box-by-box
  read the dispatcher already uses for an ISO base media path, so every C probe
  gets it without asking.
- **`reads`** — whether a container is one this build demultiplexes.
  `umov_sniff` returns `"unknown"` for the same case and names the format for
  every other, which is strictly more.
- **`durationSeconds`, `videoTrack`, `audioTrack`, `trackCount`,
  `clusterCount`, `fragmentCount`** — one-line accessors and counters over
  fields `umov_probe` already returns, or over container internals a consumer
  of decoded media has no use for.
- **`location`, `parseIso6709`** — the recording place as ISO 6109 text, read
  and parsed. `umov_probe` returns the parsed coordinates, so the string form
  is the intermediate step, not the answer.
- **`toQuickTime`, `fromQuickTime`** — the QuickTime epoch conversion the
  readers apply before any date leaves this library. A C caller receives
  seconds since the Unix epoch and never meets the other one.
- **The `Movie`, `Track` and `TrackParams` objects** — a C caller fills in or
  receives fields directly, so there is no Nim object to keep in step across
  the boundary. `umov_track_params` is the C struct that replaces the last of
  them, and the header is where its layout is fixed.

## The one place it looks inside a stream

A transport stream carries no dimensions; they live in the coded stream. A
picture size for H.264 therefore comes from the sequence parameter set, which
`mpegts.nim` reads. That produces no pixel and is not decoding — it is how
`ffprobe` answers the same question — but it is the only place this library
looks past a container, and it does so for that one codec.
