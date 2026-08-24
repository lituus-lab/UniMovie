<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0001: Where UniMovie sits, and what it may import

- Status: Accepted
- Date: 2026-08-18
- Scope: UniMovie

## Decision

UniMovie depends on `UniContainer`, and on nothing else in the family.

The edge exists for one thing: container framing. An MP4, a HEIF still and an
ALAC `.m4a` are the same box structure, and how a box is shaped is not a video
question — so `boxes` and `findBox` come from there, and so does the MP4 writer
this library exposes.

That framing was written here once, and in the image and audio libraries too,
before it was given a home below all three. A walker maintained in three places
is three chances to get a bounds check wrong.

Nothing else is taken. Demultiplexing is byte handling and integer arithmetic,
so there is nothing for a numeric or geometric layer to contribute, and an
engine that pulled one in would make every consumer carry it — UniMedia
catalogues a library by reading headers, and should not link a matrix package to
do it.

Family dependencies form a strictly acyclic graph; a library depends only on
lower layers, and a back-edge fails CI. `nimble checkVGraph` enforces both that
rule and the internal one below.

## Internal layers

`vgraph.cfg` declares them, lowest first:

```text
types < isobmff < matroska < avi < mpegts < ogg < probe < c_api
```

`types` holds what a demuxer reports and the ceilings every reader checks
against; one module per container family sits above it, none of them importing
another; `probe` dispatches over all of them; `c_api` is the shell. A container
reader that imported a sibling would mean one format's quirk had leaked into
another's parser.

## What stays out

No decoder, and no system API. A track reports the code its samples are in and
hands the bytes over unchanged; producing pixels belongs to a backend the
application registers. That is what keeps a patented decoder out of this
library and out of everything that links it.

The one exception is stated in ADR-0003.
