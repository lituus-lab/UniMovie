# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""The binding over the C ABI, on the same fixtures as the Nim suite."""
import pathlib

import pytest

from unimovie import (WRITER_MATROSKA, WRITER_MP4, WRITER_MP4_FRAGMENTED,
                      WRITER_WEBM, UniMovieError, coded_sample,
                      coded_sample_count, edit_list, open_writer, probe,
                      sample_timing, sniff, track, track_sizes, tracks,
                      version)

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


def test_sniff_names_the_container_without_reading_it():
    assert sniff(FIXTURES / "tiny.mp4") == "mp4"
    assert sniff(FIXTURES / "tiny.mkv") == "matroska"
    assert sniff(FIXTURES / "tiny.ts") == "mpegts"
    assert sniff(FIXTURES / "tiny.ogv") == "ogg"
    assert sniff(FIXTURES / "tiny.avi") == "avi"


def test_track_sizes_is_the_decoder_s_size_not_the_shown_one():
    # Square pixels: the two agree.
    assert track_sizes(FIXTURES / "tiny.mp4", 0) == (64, 48)
    # A 16:15 sample aspect: they part, and using the wrong one stretches
    # every thumbnail made from the file.
    coded = track_sizes(FIXTURES / "anamorphic.mp4", 0)
    shown = track(FIXTURES / "anamorphic.mp4", 0)
    assert coded == (64, 48)
    assert (shown["width"], shown["height"]) == (68, 48)


@pytest.mark.parametrize("name,count", [
    ("tiny.mp4", 10), ("tiny.mkv", 10), ("tiny.webm", 5),
    ("tiny.avi", 5), ("tiny.ts", 10), ("tiny.ogv", 5),
])
def test_coded_samples_come_out_of_every_container(name, count):
    path = FIXTURES / name
    assert coded_sample_count(path, 0) == count
    first = coded_sample(path, 0, 0)
    assert isinstance(first, bytes)
    assert len(first) > 0


def test_a_sample_past_the_track_raises():
    with pytest.raises(UniMovieError):
        coded_sample(FIXTURES / "tiny.mp4", 0, 9999)


def test_sample_timing_carries_the_reordering():
    timing = sample_timing(FIXTURES / "tiny.mp4", 0)
    assert len(timing) == 10
    assert all(duration > 0 for duration, _ in timing)
    # The fixture is reordered; without this the writer tests below would
    # pass on a binding that dropped the offsets.
    assert any(offset != 0 for _, offset in timing)


def test_sample_timing_is_empty_where_the_container_has_none():
    assert sample_timing(FIXTURES / "tiny.mkv", 0) == []


def test_edit_list_reads_back_what_the_fixture_carries():
    edits = edit_list(FIXTURES / "tiny.mp4", 0)
    assert edits == [(1000, 2048)]
    assert edit_list(FIXTURES / "tiny.mkv", 0) == []


@pytest.mark.parametrize("kind,suffix", [
    (WRITER_MP4, ".mp4"),
    (WRITER_MP4_FRAGMENTED, ".mp4"),
    (WRITER_MATROSKA, ".mkv"),
    (WRITER_WEBM, ".webm"),
])
def test_a_remux_through_the_writer_keeps_every_sample(tmp_path, kind, suffix):
    source = FIXTURES / "tiny.mp4"
    timing = sample_timing(source, 0)
    target = tmp_path / ("out" + suffix)
    spec = [{"kind": "video", "codec": "avc1", "timescale": 10240,
             "width": 64, "height": 48}]
    with open_writer(target, spec, kind) as writer:
        for index, (duration, offset) in enumerate(timing):
            writer.write(0, coded_sample(source, 0, index), duration,
                         keyframe=(index == 0), composition_offset=offset)
            if index == 4:
                writer.flush()
    assert coded_sample_count(target, 0) == len(timing)
    for index in range(len(timing)):
        assert coded_sample(target, 0, index) == coded_sample(source, 0, index)


def test_the_writer_closes_itself_when_the_loop_raises(tmp_path):
    target = tmp_path / "aborted.mp4"
    spec = [{"kind": "video", "codec": "avc1", "timescale": 1000,
             "width": 16, "height": 16}]
    with pytest.raises(RuntimeError):
        with open_writer(target, spec) as writer:
            writer.write(0, b"\x00\x01\x02", 100)
            raise RuntimeError("the caller gave up")
    # Closed on the way out, so the file has its index rather than none.
    assert target.exists()
    assert coded_sample_count(target, 0) == 1


def test_the_writer_refuses_what_it_cannot_write(tmp_path):
    with pytest.raises(ValueError):
        open_writer(tmp_path / "x.mp4", [])
    with pytest.raises(ValueError):
        open_writer(tmp_path / "x.mp4",
                    [{"kind": "video", "codec": "avc", "timescale": 1000,
                      "width": 16, "height": 16}])
    with pytest.raises(UniMovieError):
        # A video track with no dimensions: refused by the muxer itself.
        open_writer(tmp_path / "x.mp4",
                    [{"kind": "video", "codec": "avc1", "timescale": 1000}])


def test_a_spent_writer_refuses_a_second_close(tmp_path):
    target = tmp_path / "spent.mp4"
    spec = [{"kind": "video", "codec": "avc1", "timescale": 1000,
             "width": 16, "height": 16}]
    writer = open_writer(target, spec)
    writer.write(0, b"\x00\x01\x02", 100)
    writer.close()
    writer.close()  # a second close is a no-op, not an error
