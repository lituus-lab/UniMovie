// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#ifndef UNIMOVIE_H
#define UNIMOVIE_H

#include <stddef.h>

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
 * the size the track is SHOWN at and are zero for a track that is not video;
 * umov_track_sizes gives the size its decoder produces. */
int umov_track(const char *path, int index, int *kind, char codec[5],
               int *width, int *height, int *rotation, int *sample_count,
               int *keyframe_count);

/* The size a track's decoder produces, which is not always the size it is
 * shown at: the two differ by the sample aspect ratio. Compare a decoded frame
 * against this pair. Zero where the container does not say, and for audio. */
int umov_track_sizes(const char *path, int index, int *coded_width,
                     int *coded_height);

/* Which container a file is, from its leading bytes only -- "mp4",
 * "matroska", "avi", "mpegts", "ogg", or "unknown". Answers for a file this
 * build cannot read as well as for one it can. format takes sixteen bytes. */
int umov_sniff(const char *path, char format[16]);

/* How many coded samples a track holds. ISO base media reads this from a
 * table; every other container is walked to find out, on every call. */
int umov_coded_sample_count(const char *path, int track, int *count);

/* The coded bytes of one sample, exactly as the file holds them.
 *
 * Two calls: pass buffer = NULL to learn the size, then call again with one
 * that large. written receives the size either way, and a buffer smaller than
 * it is refused rather than filled part-way.
 *
 * The bytes come back in the form the container stores -- an MP4 gives
 * length-prefixed units where a transport stream gives start codes. Converting
 * between them is the decoder backend's business. */
int umov_coded_sample(const char *path, int track, int index,
                      unsigned char *buffer, size_t capacity, size_t *written);

/* Per-sample decode duration and composition offset, in the track's own
 * timescale. ISO base media only; another container reports zero samples.
 * Two calls, as above: NULL arrays learn the count. Both are filled together,
 * since writing samples back without their offsets puts a reordered stream out
 * of order. */
int umov_sample_timing(const char *path, int track, int *durations,
                       int *composition_offsets, int capacity, int *written);

/* A track's edit list -- what it says about when its media plays. ISO base
 * media only. Durations are in the movie timescale and media times in the
 * track's; a media time of -1 is an empty edit, which plays nothing for its
 * duration. Two calls, as above. A remux that drops this plays out of sync
 * rather than producing a malformed file. */
int umov_edit_list(const char *path, int track, long long *durations,
                   long long *media_times, int capacity, int *written);

/* ---- Writing ---------------------------------------------------------- */

/* Which shape of file to write. */
typedef enum {
  UMOV_WRITER_MP4 = 0,             /* one file, moov written at close */
  UMOV_WRITER_MP4_FRAGMENTED = 1,  /* moov first, then moof/mdat per fragment */
  UMOV_WRITER_MATROSKA = 2,
  UMOV_WRITER_WEBM = 3             /* Matroska's restricted doc type */
} umov_writer_kind;

/* One track, before any sample of it exists.
 *
 * codec is the four-character code the samples are in -- "avc1", "hvc1",
 * "av01", "mp4a", "alac" -- and must match the bytes. config_kind names the
 * codec configuration box inside an MP4 sample entry ("avcC", "hvcC", "av1C",
 * "esds", "alac"); leave it empty for a codec that needs none.
 *
 * config is that configuration's payload, copied unexamined. Writing Matroska
 * it becomes CodecPrivate, and for AAC that is the AudioSpecificConfig rather
 * than the whole esds -- a config still labelled "esds" is refused, because
 * handed the descriptor tree a player drops the track and the file still looks
 * well formed.
 *
 * The edit arrays say when the media plays: a media time of -1 is an empty
 * edit lasting its duration, any other value starts playback that far in.
 * Durations are in milliseconds; a duration of 0 means the rest of the track.
 * Leave them NULL for a track that plays from its start. */
typedef struct {
  int kind;                 /* umov_track_kind: video or audio, not other */
  char codec[5];
  int timescale;            /* units per second this track's times are in */
  int width, height;        /* video only */
  int channels, sample_rate; /* audio only */
  char config_kind[5];
  const unsigned char *config;
  size_t config_len;
  const long long *edit_durations;
  const long long *edit_media_times;
  int edit_count;
} umov_track_params;

/* Open a writer. The handle is valid on the calling thread until
 * umov_writer_close; zero is never a valid handle.
 *
 * Nothing is encoded here. The caller hands over samples some encoder already
 * produced, which is what keeps this library clear of any codec. */
int umov_writer_open(const char *path, int kind,
                     const umov_track_params *tracks, int track_count,
                     int *handle);

/* Append one coded sample, duration units of that track's timescale long.
 * keyframe non-zero says it decodes on its own. composition_offset is how far
 * its display time sits from its decode time -- non-zero only where an encoder
 * reordered, and it must be passed through or the stream plays out of order.
 * The bytes are copied before this returns. */
int umov_writer_sample(int handle, int track, const unsigned char *data,
                       size_t length, int duration, int keyframe,
                       int composition_offset);

/* End the current fragment or cluster, so what is written so far can be played
 * on its own. A whole-file MP4 has no such boundary and succeeds without doing
 * anything, so one loop serves every kind. A fragment that does not start on a
 * keyframe cannot be played alone, so where it breaks is the caller's call. */
int umov_writer_flush(int handle);

/* How many samples of a track are buffered for the next fragment or cluster,
 * and how many boundaries have been written. flushed is fragments for a
 * fragmented MP4 and cue points for a Matroska; a whole-file MP4 has neither
 * and reports 0, with pending counting every sample written so far. Matroska
 * buffers a cluster rather than a track, so its pending is always 0. */
int umov_writer_counts(int handle, int track, int *pending, int *flushed);

/* Finish the file and release the handle. The handle is invalid afterwards
 * whether or not this succeeded. */
int umov_writer_close(int handle);

#ifdef __cplusplus
}
#endif

#endif /* UNIMOVIE_H */
