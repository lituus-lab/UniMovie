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

  printf("c abi: ok\n");
  return 0;
}
