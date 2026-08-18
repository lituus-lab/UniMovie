<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# book

`index.nim` is a [nimib](https://github.com/pietroppeter/nimib) document: its
code blocks are compiled and run when the page is built, and the output shown
is what they actually produced. Prose that outlives the API it describes breaks
the build rather than quietly misleading a reader.

```bash
nimble book    # -> book/index.html
nimble docs    # the book plus the API reference -> pages/
```

`nbSave` must be the last statement in the file. Anything after it renders as
source text instead of running, which looks like a documented example while
proving nothing.
