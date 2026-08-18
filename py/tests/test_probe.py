# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""The binding over the C ABI, on the same fixtures as the Nim suite."""
import pathlib

import pytest

from unimovie import UniMovieError, probe, track, tracks, version

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "tests" / "fixtures"


def test_version_is_a_string():
    assert version()


def test_probe_reports_the_shape():
    count, video, audio, seconds, fmt = probe(FIXTURES / "tiny.mp4")
    assert count == 1
    assert video == 0
    assert audio == -1        # absent, not an error
    assert 0.9 < seconds < 1.1
    assert fmt == "isom"


@pytest.mark.parametrize("name,fmt", [
    ("tiny.mp4", "isom"),
    ("rotated.mov", "mov"),
    ("tiny.mkv", "matroska"),
    ("tiny.webm", "webm"),
    ("tiny.avi", "avi"),
])
def test_every_container_goes_through_one_call(name, fmt):
    count, video, _, seconds, found = probe(FIXTURES / name)
    assert found == fmt
    assert count >= 1
    assert video == 0
    assert 0.9 < seconds < 1.1


def test_track_reports_the_container_code():
    info = track(FIXTURES / "tiny.mp4", 0)
    assert info["kind"] == "video"
    assert info["codec"] == "avc1"
    assert (info["width"], info["height"]) == (64, 48)
    assert info["rotation"] == 0
    assert 0 < info["keyframe_count"] < info["sample_count"]


def test_rotation_is_clockwise():
    # ffprobe calls this rotation=90 counting anticlockwise.
    video = probe(FIXTURES / "rotated.mov")[1]
    assert track(FIXTURES / "rotated.mov", video)["rotation"] == 270


def test_tracks_lists_every_one():
    found = tracks(FIXTURES / "av.mp4")
    assert [t["kind"] for t in found] == ["video", "audio"]


def test_a_missing_file_raises():
    with pytest.raises(UniMovieError):
        probe(FIXTURES / "no-such-file.mp4")


def test_an_index_past_the_file_raises():
    with pytest.raises(UniMovieError):
        track(FIXTURES / "tiny.mp4", 99)
