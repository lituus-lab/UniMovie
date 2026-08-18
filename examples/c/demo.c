// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/* Name a file and it says what is inside — through the C ABI only. */
#include "UniMovie.h"

#include <stdio.h>

int main(int argc, char **argv) {
  printf("UniMovie %s\n", umov_version());
  if (argc < 2) {
    printf("usage: demo <video file>\n");
    return 0;
  }
  const char *path = argv[1];

  int tracks = 0, video = -1, audio = -1;
  double duration = 0.0;
  char format[16];
  if (umov_probe(path, &tracks, &video, &audio, &duration, format) != UMOV_OK) {
    printf("%s: %s\n", path, umov_last_error());
    return 1;
  }
  printf("%s: %s, %.3f s, %d track(s), video=%d audio=%d\n", path, format,
         duration, tracks, video, audio);

  for (int index = 0; index < tracks; index++) {
    int kind = 0, width = 0, height = 0, rotation = 0, samples = 0, keys = 0;
    char codec[5];
    if (umov_track(path, index, &kind, codec, &width, &height, &rotation,
                   &samples, &keys) != UMOV_OK) {
      printf("  [%d] %s\n", index, umov_last_error());
      continue;
    }
    printf("  [%d] %s %s %dx%d rot=%d, %d samples, %d keyframes\n", index,
           kind == UMOV_TRACK_VIDEO   ? "video"
           : kind == UMOV_TRACK_AUDIO ? "audio"
                                      : "other",
           codec, width, height, rotation, samples, keys);
  }
  return 0;
}
