# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# cython: language_level=3
"""Cython binding over the UniMovie C library."""

cdef extern from "UniMovie.h":
    const char *umov_version()
    const char *umov_last_error()
    int umov_probe(const char *path, int *track_count, int *video_index,
                   int *audio_index, double *duration_seconds, char *format)
    int umov_track(const char *path, int index, int *kind, char *codec,
                   int *width, int *height, int *rotation, int *sample_count,
                   int *keyframe_count)
    int umov_track_sizes(const char *path, int index, int *coded_width,
                         int *coded_height)
    int umov_sniff(const char *path, char *format)
    int umov_location(const char *path, double *latitude, double *longitude,
                      int *found)
    int umov_coded_sample_count(const char *path, int track, int *count)
    int umov_coded_sample(const char *path, int track, int index,
                          unsigned char *buffer, size_t capacity,
                          size_t *written)
    int umov_sample_timing(const char *path, int track, int *durations,
                           int *composition_offsets, int capacity,
                           int *written)
    int umov_edit_list(const char *path, int track, long long *durations,
                       long long *media_times, int capacity, int *written)

    ctypedef struct umov_track_params:
        int kind
        char codec[5]
        int timescale
        int width
        int height
        int channels
        int sample_rate
        char config_kind[5]
        const unsigned char *config
        size_t config_len
        const long long *edit_durations
        const long long *edit_media_times
        int edit_count

    int umov_writer_open(const char *path, int kind,
                         const umov_track_params *tracks, int track_count,
                         int *handle)
    int umov_writer_sample(int handle, int track, const unsigned char *data,
                           size_t length, int duration, int keyframe,
                           int composition_offset)
    int umov_writer_flush(int handle)
    int umov_writer_counts(int handle, int track, int *pending,
                           int *flushed)
    int umov_writer_close(int handle)

from libc.stdlib cimport malloc, free
from libc.string cimport memset, strncpy

_KINDS = ("video", "audio", "other")

#: The four shapes :func:`open_writer` can produce.
WRITER_MP4 = 0
WRITER_MP4_FRAGMENTED = 1
WRITER_MATROSKA = 2
WRITER_WEBM = 3


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

    Returns ``(track_count, video_index, audio_index, duration_seconds,
    format)``, where an absent video or audio track is ``-1`` rather than an
    error.

    ``format`` is the container's own name — ``matroska``, ``webm``, ``avi``
    — except for an ISO base media file, which reports its major brand:
    ``isom``, ``mp42``, ``qt  ``. There is no single ``mp4`` answer to give,
    since the brand is what the file itself claims to be.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int tracks = 0, video = -1, audio = -1
    cdef double duration = 0.0
    cdef char format[16]
    _check(umov_probe(encoded, &tracks, &video, &audio, &duration, format))
    return (tracks, video, audio, duration,
            format.decode("ascii", "replace"))


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
    count = probe(path)[0]
    return [track(path, index) for index in range(count)]


def track_sizes(path, int index):
    """The size a track's decoder produces, as ``(width, height)``.

    Not always what :func:`track` reports: that one is the size the track is
    *shown* at, and the two differ by the sample aspect ratio. Compare a
    decoded frame against this pair — the other stretches it.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int width = 0, height = 0
    _check(umov_track_sizes(encoded, index, &width, &height))
    return (width, height)


def sniff(path):
    """Which container a file is, from its leading bytes only.

    Answers ``mp4``, ``matroska``, ``avi``, ``mpegts``, ``ogg`` or ``unknown``
    — for a file this build cannot read as well as for one it can.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char format[16]
    _check(umov_sniff(encoded, format))
    return format.decode("ascii", "replace")


def coded_sample_count(path, int track):
    """How many coded samples a track holds.

    ISO base media reads this from a table; every other container is walked to
    find out, on this call and on every one after it.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int count = 0
    _check(umov_coded_sample_count(encoded, track, &count))
    return count


def coded_sample(path, int track, int index):
    """The coded bytes of one sample, exactly as the file holds them.

    The form is the container's own: an MP4 gives length-prefixed units where
    a transport stream gives start codes. Converting between them is the
    decoder backend's business, and doing it here would hide which you have.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef size_t needed = 0
    _check(umov_coded_sample(encoded, track, index, NULL, 0, &needed))
    cdef unsigned char *buffer = <unsigned char *>malloc(needed if needed else 1)
    if buffer == NULL:
        raise MemoryError("cannot allocate a sample buffer")
    cdef size_t written = 0
    try:
        _check(umov_coded_sample(encoded, track, index, buffer, needed,
                                 &written))
        return bytes(buffer[:written])
    finally:
        free(buffer)


def sample_timing(path, int track):
    """Per-sample ``(duration, composition_offset)``, in the track's timescale.

    ISO base media only; another container reports an empty list. The offset is
    how far a sample's display time sits from its decode time — anything
    rewriting a track needs both, or a reordered stream comes out in the wrong
    order.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int count = 0
    _check(umov_sample_timing(encoded, track, NULL, NULL, 0, &count))
    if count == 0:
        return []
    cdef int *durations = <int *>malloc(count * sizeof(int))
    cdef int *offsets = <int *>malloc(count * sizeof(int))
    if durations == NULL or offsets == NULL:
        free(durations)
        free(offsets)
        raise MemoryError("cannot allocate the timing arrays")
    try:
        _check(umov_sample_timing(encoded, track, durations, offsets, count,
                                  &count))
        return [(durations[i], offsets[i]) for i in range(count)]
    finally:
        free(durations)
        free(offsets)


def edit_list(path, int track):
    """A track's edit list as ``(duration, media_time)`` pairs.

    Durations are in the movie timescale and media times in the track's. A
    media time of ``-1`` is an empty edit, which plays nothing for its
    duration. A remux that drops this plays out of sync rather than producing a
    malformed file.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int count = 0
    _check(umov_edit_list(encoded, track, NULL, NULL, 0, &count))
    if count == 0:
        return []
    cdef long long *durations = <long long *>malloc(count * sizeof(long long))
    cdef long long *times = <long long *>malloc(count * sizeof(long long))
    if durations == NULL or times == NULL:
        free(durations)
        free(times)
        raise MemoryError("cannot allocate the edit arrays")
    try:
        _check(umov_edit_list(encoded, track, durations, times, count, &count))
        return [(durations[i], times[i]) for i in range(count)]
    finally:
        free(durations)
        free(times)


cdef class Writer:
    """An open file being written, one sample at a time.

    Nothing is encoded. The caller hands over samples some encoder already
    produced, which is what keeps this library clear of any codec.

    Use it as a context manager so the file is finished even if the loop
    raises; a writer that is never closed leaves a file with no index.
    """

    cdef int _handle

    def __cinit__(self, path, tracks, int kind=WRITER_MP4):
        cdef bytes encoded = str(path).encode("utf-8")
        cdef int count = len(tracks)
        if count < 1:
            raise ValueError("a file needs at least one track")
        cdef umov_track_params *params = <umov_track_params *>malloc(
            count * sizeof(umov_track_params))
        if params == NULL:
            raise MemoryError("cannot allocate the track table")
        # The bytes objects are kept alive for the whole call: the struct holds
        # borrowed pointers, and the library copies them before it returns.
        keepalive = []
        cdef bytes codec_bytes
        cdef bytes config_kind_bytes
        cdef bytes config_bytes
        cdef int handle = 0
        try:
            memset(params, 0, count * sizeof(umov_track_params))
            for i, spec in enumerate(tracks):
                kind_name = spec.get("kind")
                if kind_name == "audio":
                    params[i].kind = 1
                elif kind_name == "video":
                    params[i].kind = 0
                else:
                    raise ValueError(
                        "a track is \"video\" or \"audio\", not "
                        + repr(kind_name))
                codec_bytes = str(spec["codec"]).encode("ascii")
                if len(codec_bytes) != 4:
                    raise ValueError("a codec is four characters")
                strncpy(params[i].codec, codec_bytes, 4)
                params[i].timescale = int(spec["timescale"])
                params[i].width = int(spec.get("width", 0))
                params[i].height = int(spec.get("height", 0))
                params[i].channels = int(spec.get("channels", 0))
                params[i].sample_rate = int(spec.get("sample_rate", 0))
                config_kind_bytes = str(spec.get("config_kind", "")).encode("ascii")
                if config_kind_bytes:
                    if len(config_kind_bytes) != 4:
                        raise ValueError(
                            "a config kind is four characters, or empty")
                    strncpy(params[i].config_kind, config_kind_bytes, 4)
                config_bytes = bytes(spec.get("config", b""))
                if config_bytes:
                    keepalive.append(config_bytes)
                    params[i].config = <const unsigned char *>config_bytes
                    params[i].config_len = len(config_bytes)
            _check(umov_writer_open(encoded, kind, params, count, &handle))
            self._handle = handle
        finally:
            free(params)

    def write(self, int track, data, int duration, keyframe=True,
              int composition_offset=0):
        """Append one coded sample, ``duration`` units of its track's timescale.

        ``composition_offset`` is how far the sample's display time sits from
        its decode time, and must be passed through where an encoder reordered.
        """
        cdef bytes payload = bytes(data)
        if not payload:
            raise ValueError("an empty sample has no meaning")
        _check(umov_writer_sample(self._handle, track, payload, len(payload),
                                  duration, 1 if keyframe else 0,
                                  composition_offset))

    def flush(self):
        """End the current fragment or cluster.

        A whole-file MP4 has no such boundary and this does nothing, so one
        loop serves every shape. A fragment that does not start on a keyframe
        cannot be played alone, so where it breaks is the caller's decision.
        """
        _check(umov_writer_flush(self._handle))

    def counts(self, int track=0):
        """``(pending, flushed)`` for a track.

        ``pending`` is how many samples are waiting for the next boundary and
        ``flushed`` how many boundaries have been written -- fragments for a
        fragmented MP4, cue points for a Matroska. A whole-file MP4 has no
        boundary, so it reports every sample as pending and none flushed.
        """
        cdef int pending = 0, flushed = 0
        _check(umov_writer_counts(self._handle, track, &pending, &flushed))
        return (pending, flushed)

    def close(self):
        """Finish the file. The writer is spent afterwards."""
        if self._handle != 0:
            handle, self._handle = self._handle, 0
            _check(umov_writer_close(handle))

    def __dealloc__(self):
        # A writer that is dropped without being closed still holds a handle
        # the library pinned for it. Releasing it here is what keeps that a
        # missing index rather than a leak that lasts the process.
        #
        # The status is discarded and nothing here raises: an exception from
        # __dealloc__ cannot be propagated and would only be printed and
        # swallowed. close() stays the documented path, and the one that
        # reports what went wrong.
        if self._handle != 0:
            umov_writer_close(self._handle)
            self._handle = 0

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()
        return False


def open_writer(path, tracks, kind=WRITER_MP4):
    """Open a :class:`Writer` over ``path``.

    ``tracks`` is a list of dicts: ``kind`` (``"video"``/``"audio"``),
    ``codec``, ``timescale``, and then ``width``/``height`` for video or
    ``channels``/``sample_rate`` for audio. ``config_kind``/``config`` carry
    the codec's setup bytes where it has any.
    """
    return Writer(path, tracks, kind)


def location(path):
    """Where a recording says it was made, as ``(latitude, longitude)``.

    ``None`` when the file carries no position, which most do not. Latitude 0,
    longitude 0 is a real point in the Atlantic, so absence is reported as
    nothing rather than as a pair of zeros.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef double latitude = 0.0, longitude = 0.0
    cdef int found = 0
    _check(umov_location(encoded, &latitude, &longitude, &found))
    return (latitude, longitude) if found else None
