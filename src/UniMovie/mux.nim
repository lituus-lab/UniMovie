# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Writing an MP4.
##
## The muxer itself lives in `UniContainer`, which owns container framing for
## the family: assembling boxes needs no knowledge of what a sample decodes to,
## and three libraries had written it three times before it moved there.
##
## Re-exported here so a caller that reads a movie with this library and writes
## one back names a single import for both.

import UniContainer/mp4
export mp4


