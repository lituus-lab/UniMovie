<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# bench — what a probe costs

Isolated benchmark harness. **Not part of the default gate** (`test` /
`testAll` / `lint` / `checkVGraph` / `docs`); run it explicitly:

```bash
nimble bench          # print the timings
nimble benchReadme    # print them and splice them into this file
```

It builds with `-d:release`, so the `NimContracts` preconditions compile away
and the timings reflect the code that ships. The fixtures are read by relative
path, so the run has to start from the repository root — which is what both
tasks do.

## What is measured

The same question, asked two ways: the dimensions, duration and codec of one
file, read in process, against one `ffprobe` invocation. That is the whole
reason this library exists — a catalogue scanning a thousand files pays the
process spawn a thousand times.

## Reading the numbers

**The ratio is a process-spawn cost, not a parsing speed.** `ffprobe` parses
these headers in well under a millisecond; almost all of the twenty it takes is
`fork`, `exec`, dynamic linking and its own start-up. Comparing the two is
still the honest comparison, because spawning it is what a caller actually does
— but nothing here says `ffprobe`'s parser is slow.

The in-process column is wall time for one `readMovieFile`, median of two
hundred runs, on a file already in the page cache. It includes reading the file
from disk, which for a header-only parse is most of the work.

The fixtures are a few kilobytes each. A two-hour recording has a larger `moov`
to walk and a longer sample table to build, so its in-process cost is higher;
the `ffprobe` side barely moves, because the spawn dominates. Treat the ratio as
a floor rather than a headline.

Every timed result feeds a non-inline sink printed at the end of the run.
Without it a release build is free to notice a decoded header is never read and
delete the call, which would read as an implausibly fast probe rather than a
missing one.

## Results

Written by `nimble benchReadme` from a real run. Each machine keeps its own
block, so a second one appends rather than overwriting the first.

<!-- bench:insert -->

<!-- bench:machine=macosx-apple-m4 -->

| file | container | in process | ffprobe | ratio |
| --- | --- | ---: | ---: | ---: |
| tiny.mp4 | mp4 | 10.0 us | 18.7 ms | 1870x |
| av.mp4 | mp4 | 12.0 us | 19.6 ms | 1635x |
| rotated.mov | mp4 | 11.0 us | 20.4 ms | 1856x |
| tiny.mkv | matroska | 10.0 us | 18.0 ms | 1796x |
| tiny.webm | matroska | 10.0 us | 18.2 ms | 1817x |
| tiny.avi | avi | 11.0 us | 19.3 ms | 1751x |
| tiny.ts | mpegts | 14.0 us | 19.0 ms | 1354x |
| tiny.ogv | ogg | 9.0 us | 18.0 ms | 1995x |

Over the eight fixtures: 87 us in process, 151 ms through ffprobe.

<!-- /bench:machine=macosx-apple-m4 -->
