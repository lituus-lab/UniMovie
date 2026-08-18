<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# unimovie — Python binding

```bash
nimble clib                                              # build the shared library
cd py && python3 setup.py build_ext --inplace            # build extension
cd py && python3 -m pytest -q                            # test
```

```python
import unimovie

count, video, audio, seconds, container = unimovie.probe("clip.mp4")
unimovie.track("clip.mp4", video)
# {'kind': 'video', 'codec': 'avc1', 'width': 1920, 'height': 1080,
#  'rotation': 0, 'sample_count': 1500, 'keyframe_count': 25}
```
