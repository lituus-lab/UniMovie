<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0002: Apache-2.0, and why a demuxer can be licensed at all

- Status: Accepted
- Date: 2026-08-18
- Scope: UniMovie

## Decision

Apache-2.0 (`LICENSE`), with DCO sign-off on every commit
(`CONTRIBUTING.md`). `NOTICE` records the one bundled dependency,
`NimContracts`, which keeps its upstream MIT.

## What the licence decides

Reading a container is not a licensed act. The formats here are published —
ISO 14496-12 for MP4, the Matroska specification, ISO 13818-1 for transport
streams, RFC 3533 for Ogg — and a demuxer produces no pictures, so nothing it
does falls under a codec patent pool.

A decoder would be a different question, which is why there is none. H.264,
HEVC, AAC and ProRes carry active patent licences, and the exposure attaches to
whoever ships the decoding product. Keeping decoders out means neither this
library nor an application that links it inherits an obligation from it, and
each application calls a decoder its own platform already licenses.

A codec with no patent pool behind it does not change that shape. AV1, VP8,
VP9 and Theora are licensed royalty-free by the bodies that published them,
and the patents over MPEG-2 and baseline JPEG have expired. Those are two
different grounds — a licence granted, against a term run out — and the
second changes with jurisdiction. Either way nothing is decoded here: the
boundary is what keeps the question off this library, not the codec.

Which profile is in use, which patents still read on it, what the chosen
backend is licensed for, and how the product is distributed all remain the
caller's to establish.

This section records the reasoning behind the choice of licence. It is not
legal advice, and anyone shipping a product on top of this library owes
themselves their own reading of it.
