# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cython: language_level=3
"""Cython binding over the UniMovie C library."""

cdef extern from "UniMovie.h":
    const char *umov_version()
    const char *umov_last_error()
    int umov_probe(const char *path, int *track_count, int *video_index,
                   int *audio_index, double *duration_seconds)
    int umov_track(const char *path, int index, int *kind, char *codec,
                   int *width, int *height, int *rotation, int *sample_count,
                   int *keyframe_count)

_KINDS = ("video", "audio", "other")


class UniMovieError(Exception):
    """A container UniMovie cannot read, or an argument it refuses."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def version():
    """C library version string."""
    return umov_version().decode("ascii")


def _check(int status):
    if status != 0:
        raise UniMovieError(status,
                            umov_last_error().decode("utf-8", "replace"))


def probe(path):
    """Shape of a container.

    Returns ``(track_count, video_index, audio_index, duration_seconds)``,
    where an absent video or audio track is ``-1`` rather than an error.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int tracks = 0, video = -1, audio = -1
    cdef double duration = 0.0
    _check(umov_probe(encoded, &tracks, &video, &audio, &duration))
    return tracks, video, audio, duration


def track(path, int index):
    """One track's shape, as a dict.

    ``rotation`` is clockwise degrees; ffprobe reports the same matrix counting
    anticlockwise, so its 90 is this library's 270. ``codec`` is the
    container's own four-character code — ``avc1``, ``hvc1``, ``av01`` — not a
    friendlier name, because that is what a decoder backend registers under.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int kind = 0, width = 0, height = 0, rotation = 0
    cdef int samples = 0, keyframes = 0
    cdef char codec[5]
    _check(umov_track(encoded, index, &kind, codec, &width, &height, &rotation,
                      &samples, &keyframes))
    return {
        "kind": _KINDS[kind] if 0 <= kind < len(_KINDS) else "other",
        "codec": codec.decode("ascii", "replace"),
        "width": width,
        "height": height,
        "rotation": rotation,
        "sample_count": samples,
        "keyframe_count": keyframes,
    }


def tracks(path):
    """Every track of a file, in order."""
    count, _, _, _ = probe(path)
    return [track(path, index) for index in range(count)]
