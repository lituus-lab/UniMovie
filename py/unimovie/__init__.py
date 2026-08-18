# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""unimovie — Python binding over the UniMovie C library.

Demultiplexing for video containers: tracks, durations, dimensions, rotation
and keyframe counts, without decoding anything::

    import unimovie

    count, video, audio, seconds = unimovie.probe("clip.mp4")
    unimovie.track("clip.mp4", video)["codec"]      # 'avc1'
"""
from ._core import (UniMovieError, probe, track, tracks,
                    version as _version_c)

__version__ = _version_c()


def version():
    """C library version string."""
    return _version_c()


__all__ = ["UniMovieError", "probe", "track", "tracks", "version",
           "__version__"]
