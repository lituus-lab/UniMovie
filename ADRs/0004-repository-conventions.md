<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0004: UniMovie conventions

- Status: Accepted
- Date: 2026-07-15
- Scope: UniMovie and the conventions every clone inherits

## Layout

```
UniMovie.nimble          package + tasks
config.nims                 arch-conditional build flags
src/UniMovie.nim         umbrella
src/UniMovie/isobmff.nim  hello-world (NimContracts)
src/UniMovie/c_api.nim   C ABI
include/UniMovie.h       hand-written C header
tests/ tests/c/             Nim + C ABI tests
examples/                   Nim + C demos
py/                         Cython binding + pytest
book/                       nimib placeholder
ADRs/                       0001–0004
.github/workflows/ci.yml    3-OS Nim + C ABI + Python
LICENSE NOTICE CONTRIBUTING.md SECURITY.md .gitignore README.md AGENTS.md CLAUDE.md
```

## Naming

- Nim package/module: `UniFoo` (PascalCase).
- C library: `libUniFoo`. C header: `UniFoo.h`.
- C symbol prefix: the lib's short token (`ut_` here; `ua_`, `um_`, `ulin_`…).

## Conventions

- Hello-world `isobmff`, exercised in Nim + C ABI + Python.
- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. The C ABI never raises — it clamps out-of-range input.
- A postcondition is cheaper than the body; it never re-derives the result.
- English comments, terse, describe what is done. No "deprecated".
- Internal `types/` never imports `algorithms/`; `io/` → `types/` only.

## CI gates

- `nimble testCi` + `testCiRelease` on ubuntu/macOS/Windows.
- `nimble ctest` on linux/macOS.
- `nimble pyTest` on linux.

## Clone map

| Template | Clone |
|---|---|
| `UniMovie` | `UniFoo` |
| `unimovie` | `unifoo` |
| `ut_` | `<short>_` |
| `libUniMovie` | `libUniFoo` |
| `UniMovie.h` | `UniFoo.h` |

After the rename, replace `isobmff.nim` with the domain module(s), update the
umbrella exports, the C ABI + header + C test + Python `_core.pyx`, and run the
gates.
