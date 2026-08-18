# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""unimovie — Python binding over the UniMovie C library.

Reading a container: tracks, durations, dimensions, rotation, keyframe counts
and the coded bytes of any sample, without decoding anything::

    import unimovie

    count, video, audio, seconds, container = unimovie.probe("clip.mp4")
    unimovie.track("clip.mp4", video)["codec"]        # 'avc1'
    unimovie.coded_sample("clip.mp4", video, 0)       # bytes, as stored

Writing one: the samples come from an encoder the caller already ran, so
nothing here carries a codec::

    with unimovie.open_writer("out.mkv", [{"kind": "video", "codec": "avc1",
                                           "timescale": 1000, "width": 64,
                                           "height": 48}],
                              unimovie.WRITER_MATROSKA) as writer:
        writer.write(0, sample_bytes, duration=40)
"""
from ._core import (WRITER_MATROSKA, WRITER_MP4, WRITER_MP4_FRAGMENTED,
                    WRITER_WEBM, UniMovieError, Writer, coded_sample,
                    coded_sample_count, edit_list, open_writer, probe,
                    sample_timing, sniff, track, track_sizes, tracks,
                    version as _version_c)

__version__ = _version_c()


def version():
    """C library version string."""
    return _version_c()


__all__ = ["UniMovieError", "Writer", "coded_sample", "coded_sample_count",
           "edit_list", "open_writer", "probe", "sample_timing", "sniff",
           "track", "track_sizes", "tracks", "version",
           "WRITER_MP4", "WRITER_MP4_FRAGMENTED", "WRITER_MATROSKA",
           "WRITER_WEBM", "__version__"]
