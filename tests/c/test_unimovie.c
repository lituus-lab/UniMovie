// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/* Links include/UniMovie.h against the static library, so a header that drifts
 * from src/UniMovie/c_api.nim fails to compile rather than at a caller's site.
 *
 * It probes a fixture from the Nim suite and checks the same numbers, so the
 * ABI is verified to carry what the library found rather than merely to link.
 */
#include "UniMovie.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : "../fixtures/tiny.mp4";

  assert(strlen(umov_version()) > 0);
  assert(strcmp(umov_last_error(), "") == 0);

  int tracks = 0, video = -2, audio = -2;
  double duration = -1.0;
  char format[16];
  assert(umov_probe(path, &tracks, &video, &audio, &duration, format) == UMOV_OK);
  assert(strcmp(format, "isom") == 0);
  assert(tracks == 1);
  assert(video == 0);
  assert(audio == -1); /* no audio track: -1, not an error */
  assert(duration > 0.9 && duration < 1.1);

  int kind = -1, width = 0, height = 0, rotation = -1, samples = 0, keys = 0;
  char codec[5];
  assert(umov_track(path, 0, &kind, codec, &width, &height, &rotation, &samples,
                    &keys) == UMOV_OK);
  assert(kind == UMOV_TRACK_VIDEO);
  assert(strcmp(codec, "avc1") == 0);
  assert(width == 64 && height == 48);
  assert(rotation == UMOV_ROT_0);
  assert(samples == 10);
  assert(keys > 0 && keys < samples);

  /* A rotated track, on the fixture that carries a real display matrix. The
   * value is degrees clockwise, so an ordinal would read as 3 and pass a
   * check written against UMOV_ROT_270 only by accident. */
  {
    const char *rotated = argc > 2 ? argv[2] : "../fixtures/rotated.mov";
    int rkind = -1, rwidth = 0, rheight = 0, rrot = -1, rsamples = 0, rkeys = 0;
    char rcodec[5];
    assert(umov_track(rotated, 0, &rkind, rcodec, &rwidth, &rheight, &rrot,
                      &rsamples, &rkeys) == UMOV_OK);
    assert(rrot == UMOV_ROT_270);
    assert(rrot == 270);
  }

  /* Out-of-range input is refused, not clamped. */
  assert(umov_probe(NULL, &tracks, &video, &audio, &duration, format) ==
         UMOV_ERR_ARG);
  /* format is the one optional argument. */
  assert(umov_probe(path, &tracks, &video, &audio, &duration, NULL) == UMOV_OK);
  assert(umov_track(path, -1, &kind, codec, &width, &height, &rotation,
                    &samples, &keys) == UMOV_ERR_ARG);
  assert(umov_track(path, 99, &kind, codec, &width, &height, &rotation,
                    &samples, &keys) == UMOV_ERR_ARG);
  assert(strlen(umov_last_error()) > 0);

  /* A file that is not there is IO, not format. */
  assert(umov_probe("no-such-file.mp4", &tracks, &video, &audio, &duration,
                    format) == UMOV_ERR_IO);

  /* A Matroska file through the same entry point: the ABI dispatches on the
   * bytes, so one call serves every container this build reads. */
  {
    const char *mkv = argc > 3 ? argv[3] : "../fixtures/tiny.mkv";
    int mtracks = 0, mvideo = -1, maudio = -1;
    double mduration = 0.0;
    char mformat[16];
    if (umov_probe(mkv, &mtracks, &mvideo, &maudio, &mduration, mformat) ==
        UMOV_OK) {
      assert(strcmp(mformat, "matroska") == 0);
      assert(mvideo == 0);
    }
  }

  /* The coded size, which is not the displayed one on an anamorphic source. */
  {
    const char *ana = argc > 4 ? argv[4] : "../fixtures/anamorphic.mp4";
    int aw = 0, ah = 0, cw = 0, ch = 0;
    int akind, arot, asamples, akeys;
    char acodec[5];
    assert(umov_track(ana, 0, &akind, acodec, &aw, &ah, &arot, &asamples,
                      &akeys) == UMOV_OK);
    assert(umov_track_sizes(ana, 0, &cw, &ch) == UMOV_OK);
    assert(cw == 64 && ch == 48); /* what the decoder produces */
    assert(aw == 68 && ah == 48); /* what it is shown at, 16:15 wider */
    assert(cw != aw);
  }

  /* The container, from the leading bytes only. */
  {
    char sniffed[16];
    assert(umov_sniff(path, sniffed) == UMOV_OK);
    assert(strcmp(sniffed, "mp4") == 0);
    assert(umov_sniff("../fixtures/tiny.ts", sniffed) == UMOV_OK);
    assert(strcmp(sniffed, "mpegts") == 0);
  }

  /* Coded samples, sized then fetched. */
  {
    int count = 0;
    size_t need = 0, got = 0;
    assert(umov_coded_sample_count(path, 0, &count) == UMOV_OK);
    assert(count == 10);
    assert(umov_coded_sample(path, 0, 0, NULL, 0, &need) == UMOV_OK);
    assert(need > 0);
    unsigned char *bytes = (unsigned char *)malloc(need);
    assert(bytes != NULL);
    /* A buffer smaller than the sample is refused, not filled part-way. */
    assert(umov_coded_sample(path, 0, 0, bytes, need - 1, &got) ==
           UMOV_ERR_ARG);
    assert(umov_coded_sample(path, 0, 0, bytes, need, &got) == UMOV_OK);
    assert(got == need);
    free(bytes);
    assert(umov_coded_sample(path, 0, 9999, NULL, 0, &need) == UMOV_ERR_FORMAT);
  }

  /* Timing and the edit list: the fixture is reordered and carries an edit
   * that cancels the offset it begins with. */
  {
    int written = 0;
    assert(umov_sample_timing(path, 0, NULL, NULL, 0, &written) == UMOV_OK);
    assert(written == 10);
    int durations[16], offsets[16];
    assert(umov_sample_timing(path, 0, durations, offsets, 16, &written) ==
           UMOV_OK);
    int reordered = 0;
    for (int i = 0; i < written; i++) {
      assert(durations[i] > 0);
      if (offsets[i] != 0) reordered = 1;
    }
    assert(reordered);

    int edits = 0;
    long long edurations[8], etimes[8];
    assert(umov_edit_list(path, 0, NULL, NULL, 0, &edits) == UMOV_OK);
    assert(edits == 1);
    assert(umov_edit_list(path, 0, edurations, etimes, 8, &edits) == UMOV_OK);
    assert(etimes[0] == 2048);
  }

  /* Writing. Every sample of the fixture is read out and written back into
   * each of the four shapes, then read again through the same ABI -- so the
   * writing half is checked to carry the bytes, not merely to link. */
  {
    const int kinds[4] = {UMOV_WRITER_MP4, UMOV_WRITER_MP4_FRAGMENTED,
                          UMOV_WRITER_MATROSKA, UMOV_WRITER_WEBM};
    const char *names[4] = {"abi-out.mp4", "abi-out-frag.mp4", "abi-out.mkv",
                            "abi-out.webm"};
    int timings[16], offsets[16], written = 0;
    assert(umov_sample_timing(path, 0, timings, offsets, 16, &written) ==
           UMOV_OK);

    for (int k = 0; k < 4; k++) {
      umov_track_params params;
      memset(&params, 0, sizeof(params));
      params.kind = UMOV_TRACK_VIDEO;
      strcpy(params.codec, "avc1");
      params.timescale = 10240;
      params.width = 64;
      params.height = 48;

      int handle = 0;
      assert(umov_writer_open(names[k], kinds[k], &params, 1, &handle) ==
             UMOV_OK);
      assert(handle != 0);
      for (int i = 0; i < written; i++) {
        size_t need = 0;
        assert(umov_coded_sample(path, 0, i, NULL, 0, &need) == UMOV_OK);
        unsigned char *bytes = (unsigned char *)malloc(need);
        size_t got = 0;
        assert(umov_coded_sample(path, 0, i, bytes, need, &got) == UMOV_OK);
        assert(umov_writer_sample(handle, 0, bytes, got, timings[i],
                                  i == 0 ? 1 : 0, offsets[i]) == UMOV_OK);
        free(bytes);
        if (i == 4) assert(umov_writer_flush(handle) == UMOV_OK);
      }
      int pending = -1, flushed = -1;
      assert(umov_writer_counts(handle, 0, &pending, &flushed) == UMOV_OK);
      assert(pending >= 0 && flushed >= 0);
      assert(umov_writer_counts(handle, 99, &pending, &flushed) ==
             UMOV_ERR_ARG);
      assert(umov_writer_close(handle) == UMOV_OK);
      /* The handle is spent. */
      assert(umov_writer_close(handle) == UMOV_ERR_ARG);

      int outCount = 0;
      assert(umov_coded_sample_count(names[k], 0, &outCount) == UMOV_OK);
      assert(outCount == written);
      for (int i = 0; i < outCount; i++) {
        size_t a = 0, b = 0;
        assert(umov_coded_sample(path, 0, i, NULL, 0, &a) == UMOV_OK);
        assert(umov_coded_sample(names[k], 0, i, NULL, 0, &b) == UMOV_OK);
        assert(a == b); /* same sample, same length, through the container */
      }
      remove(names[k]);
    }

    /* A closed handle must not address the next file opened. The storage is
     * reused; the identifier is not, or a caller that kept one past close
     * writes into an unrelated file and is told nothing. */
    {
      umov_track_params one;
      memset(&one, 0, sizeof(one));
      one.kind = UMOV_TRACK_VIDEO;
      strcpy(one.codec, "avc1");
      one.timescale = 1000;
      one.width = 16;
      one.height = 16;
      unsigned char payload[3] = {1, 2, 3};
      int first = 0, second = 0;
      assert(umov_writer_open("abi-first.mp4", UMOV_WRITER_MP4, &one, 1,
                              &first) == UMOV_OK);
      assert(umov_writer_sample(first, 0, payload, 3, 100, 1, 0) == UMOV_OK);
      assert(umov_writer_close(first) == UMOV_OK);
      assert(umov_writer_open("abi-second.mp4", UMOV_WRITER_MP4, &one, 1,
                              &second) == UMOV_OK);
      assert(first != second);
      assert(umov_writer_sample(first, 0, payload, 3, 100, 1, 0) ==
             UMOV_ERR_ARG);
      /* The live handle still works, and a file with no sample cannot close. */
      assert(umov_writer_sample(second, 0, payload, 3, 100, 1, 0) == UMOV_OK);
      assert(umov_writer_close(second) == UMOV_OK);
      remove("abi-first.mp4");
      remove("abi-second.mp4");
    }

    /* A handle nobody opened, and a writer kind that does not exist. */
    assert(umov_writer_flush(4242) == UMOV_ERR_ARG);
    umov_track_params bad;
    memset(&bad, 0, sizeof(bad));
    bad.kind = UMOV_TRACK_VIDEO;
    strcpy(bad.codec, "avc1");
    bad.timescale = 1000;
    bad.width = 16;
    bad.height = 16;
    int h = 0;
    assert(umov_writer_open("abi-bad.mp4", 9, &bad, 1, &h) == UMOV_ERR_ARG);
    /* A track with no dimensions is refused by the muxer itself. */
    umov_track_params sizeless;
    memset(&sizeless, 0, sizeof(sizeless));
    sizeless.kind = UMOV_TRACK_VIDEO;
    strcpy(sizeless.codec, "avc1");
    sizeless.timescale = 1000;
    assert(umov_writer_open("abi-bad.mp4", UMOV_WRITER_MP4, &sizeless, 1, &h) ==
           UMOV_ERR_FORMAT);
    remove("abi-bad.mp4");
  }

  printf("c abi: ok\n");
  return 0;
}
