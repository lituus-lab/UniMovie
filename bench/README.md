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
| tiny.mp4 | mp4 | 19.3 us | 22.6 ms | 1167x |
| av.mp4 | mp4 | 21.3 us | 20.4 ms | 954x |
| rotated.mov | mp4 | 19.8 us | 20.5 ms | 1035x |
| tiny.mkv | matroska | 18.2 us | 20.0 ms | 1100x |
| tiny.webm | matroska | 17.1 us | 19.7 ms | 1152x |
| tiny.avi | avi | 17.2 us | 21.1 ms | 1229x |
| tiny.ts | mpegts | 21.5 us | 20.4 ms | 948x |
| tiny.ogv | ogg | 17.3 us | 19.2 ms | 1109x |

Over the eight fixtures: 151 us in process, 163 ms through ffprobe.

<!-- /bench:machine=macosx-apple-m4 -->

## Reading a header instead of a file

An ISO base media file is read box by box, so a probe costs its `moov` rather
than its media. The fixtures are a few kilobytes each and cannot show the
difference; pass a real recording to see it:

```sh
nimble bench -- /path/to/a/recording.mp4
```

Measured that way on this machine, against the same reader given the whole file
instead. The recordings are not in the repository — a file large enough to show
the difference has no business in one — so these two rows cannot be reproduced
by `nimble benchReadme` alone:

| file | size | whole file | header only | ratio |
| --- | ---: | ---: | ---: | ---: |
| a 177 MB recording | 177 MB | 19.6 ms | 0.236 ms | 83x |
| a 21 MB recording | 21 MB | 2.3 ms | 0.045 ms | 50x |

The ratio grows with the file because only one side of it does. Resident memory
moves the same way: 374 MB against 6 MB on the 177 MB file, measured with
`/usr/bin/time -l`.
