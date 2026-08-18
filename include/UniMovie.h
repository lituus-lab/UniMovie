// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#ifndef UNIMOVIE_H
#define UNIMOVIE_H

#ifdef __cplusplus
extern "C" {
#endif

#define UNIMOVIE_VERSION_MAJOR 0
#define UNIMOVIE_VERSION_MINOR 1
#define UNIMOVIE_VERSION_PATCH 0
#define UNIMOVIE_VERSION "0.1.0"

typedef enum {
  UMOV_OK = 0,
  UMOV_ERR_ARG = 1,    /* a null pointer, or an index out of range */
  UMOV_ERR_IO = 2,     /* the file could not be opened or read */
  UMOV_ERR_FORMAT = 3  /* not a container this build understands */
} umov_status;

/* What a track carries. */
typedef enum {
  UMOV_TRACK_VIDEO = 0,
  UMOV_TRACK_AUDIO = 1,
  UMOV_TRACK_OTHER = 2
} umov_track_kind;

/* Clockwise display rotation, in degrees. ffprobe reports the same matrix
 * counting anticlockwise, so its 90 is this library's 270. */
typedef enum {
  UMOV_ROT_0 = 0,
  UMOV_ROT_90 = 90,
  UMOV_ROT_180 = 180,
  UMOV_ROT_270 = 270
} umov_rotation;

/* Static version string; do not free. */
const char *umov_version(void);

/* Most recent failure on this thread, "" when there is none. Owned by the
 * library; valid until the next failing call on the same thread. */
const char *umov_last_error(void);

/* Shape of a container: track count, the index of the first video and audio
 * track (-1 when absent), the playing time in seconds, and the container's own
 * name -- "mp4", "mov", "matroska", "webm", "avi". format takes at most fifteen
 * characters and a terminating zero, so pass sixteen bytes, or NULL when the
 * name is not wanted. */
int umov_probe(const char *path, int *track_count, int *video_index,
               int *audio_index, double *duration_seconds, char format[16]);

/* One track's shape. codec receives the container's own four-character code
 * and a terminating zero, so pass an array of five bytes. width and height are
 * zero for a track that is not video. */
int umov_track(const char *path, int index, int *kind, char codec[5],
               int *width, int *height, int *rotation, int *sample_count,
               int *keyframe_count);

#ifdef __cplusplus
}
#endif

#endif /* UNIMOVIE_H */
