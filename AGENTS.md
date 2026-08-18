<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# AGENTS.md — UniMovie

## Build & gates

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # Cython + pytest (needs libUniMovie.so)
nimble example
nimble coverage   # gcov + lcov -> coverage/ (needs lcov; linux/macOS)
nimble docs       # nimib book + API reference -> pages/ (needs nimib)
```

`nimble docs` needs a complete Nim distribution: `--project` builds `dochack`,
which Homebrew's `nim` omits (no `tools/`). choosenim and the CI action ship it.

CI: 3-OS Nim matrix + C ABI (linux/macOS) + Python.

## Conventions

- English comments, terse, describe what is done. No "deprecated".
- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. C ABI never raises — it clamps out-of-range input.
- A postcondition is cheaper than the body: never re-derives the result by
  calling the function itself.
- C ABI: hand-written `include/UniMovie.h` kept in sync with
  `src/UniMovie/c_api.nim`; `tests/c` links the header against the lib.
  Built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`.
- C symbols `unimovie_*` (prefix `ut_`); lib `libUniMovie`; header `UniMovie.h`.
- `book/index.nim` is nimib: its code blocks are compiled and run at docs build,
  so prose that outlives its API breaks the build. `py/notebooks/quickstart.ipynb`
  plays the same role for Python and renders natively on GitHub.
- End covered sources with a blank line. Nim maps a trailing statement one line
  past EOF; without that line lcov aborts on `range`/`unmapped`, and `nimble
  coverage` deliberately suppresses no error so the failure stays visible.

## Scope

Private reference repo, cloned by hand to start each `Uni*`. No public template
registry. Apache-2.0, DCO.
