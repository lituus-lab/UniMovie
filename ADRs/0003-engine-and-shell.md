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
happened to ask for. Reachable from C, and from Python:

| capability | entry point |
|---|---|
| container name, track count, first video and audio track, duration | `umov_probe` |
| one track's kind, codec, dimensions, rotation, sample and keyframe counts | `umov_track` |
| the library's version | `umov_version` |
| the reason for the last failure | `umov_last_error` |

## What stays Nim-side

These are reachable from Nim only, because the ABI covers what they are for by
a better route:

- **Per-container readers** — `readMovie` on each of `isobmff`, `matroska`,
  `avi`, `mpegts`, `ogg`. `umov_probe` identifies the container from its bytes
  and dispatches; a C caller naming a format it guessed from a file extension
  would be choosing worse information over better.
- **`codedSample`** — the bytes of one sample, which only an ISOBMFF file can
  answer for today. It is the input to a decoder backend, and a backend is
  registered in the application rather than called through this ABI; exposing
  it would mean an allocation contract for a buffer whose only consumer is on
  the other side of that boundary. It goes out when a backend protocol exists
  to hand it to.
- **`sniff`, `sniffFile`, `reads`** — naming a container without reading it.
  `umov_probe` does that and more in one call, and a C caller wanting only the
  name pays a header parse it can ignore.
- **The `Movie` and `Track` objects** — a C caller receives the fields it asked
  for through out-parameters, so there is no struct to keep in sync across the
  boundary.

## The one place it looks inside a stream

A transport stream carries no dimensions; they live in the coded stream. A
picture size for H.264 therefore comes from the sequence parameter set, which
`mpegts.nim` reads. That produces no pixel and is not decoding — it is how
`ffprobe` answers the same question — but it is the only place this library
looks past a container, and it does so for that one codec.
