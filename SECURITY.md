<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# Security Policy

Report vulnerabilities privately (email the maintainer — see git history), not
via a public issue. Include: description and impact, a minimal reproducer, and
the version from `umov_version()`.

Nothing has been released yet. The `0.1.x` C ABI is not frozen.

## Surface

Every reader here parses bytes that came from a file, so a malformed or hostile
file is the surface that matters. A container's own tables say how long each
box, element or chunk is, and a file controls what they say.

- **A damaged file is reported, not fatal.** Bytes that are wrong raise
  `MovieError` and return `UMOV_ERR_FORMAT`; a file that is not there returns
  `UMOV_ERR_IO`. An index out of range or an arithmetic overflow would be a bug
  here: every declared length is checked against the enclosing element and the
  file's real size before it is used, and every count against a ceiling in
  `types.nim` before anything is allocated.
- **A walk that meets a bad length stops rather than raising**, where what came
  before it is still usable — a truncated download should cost a caller the
  tracks after the damage, not the ones before it. A file with no usable track
  at all raises.
- **The C ABI validates its arguments and rejects them.** A null pointer, a
  negative or out-of-range track index — each returns `UMOV_ERR_ARG`, with the
  reason in `umov_last_error()`. Nothing is clamped into range: a caller that
  passed nonsense is told so.
- **What the ABI cannot check** is a buffer smaller than it promised. `codec`
  takes five bytes and `format` sixteen; a caller passing less is written past,
  and no in-process check can catch it.
- **The one recursion is bounded.** `findBox` walks an ISOBMFF box path and
  stops at 32 levels, so a file whose sizes describe a cycle stops rather than
  running the stack out. No other reader recurses: Matroska, AVI, MPEG-TS and
  Ogg each walk their nesting with explicit cursors bounded by the enclosing
  element.
- **One piece of mutable state**, a per-thread string holding the last error.
  Two threads probing two files share nothing else: every table this library
  reads from is a compile-time constant.
- **The Python binding checks shapes the ABI cannot** and raises before
  crossing.

## Scope of a report

Memory safety and input handling, as above. Timing is outside it: this library
reads media headers and holds no secrets.
