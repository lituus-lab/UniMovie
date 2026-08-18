# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Prove an installed wheel works, run from outside the checkout.

`test_probe.py` finds its fixtures by walking up from its own path, which only
holds inside the repository. This copy takes them from beside itself, so CI can
drop it and a fixture into a neutral directory and check that importing
`unimovie` resolves to the installed wheel rather than to `py/unimovie` next
door — a gap that would otherwise pass while the bundled library stayed behind.
"""
import pathlib

import pytest

import unimovie

HERE = pathlib.Path(__file__).resolve().parent


def test_version_is_a_string():
    assert unimovie.version()


def test_the_bundled_library_answers():
    fixture = HERE / "tiny.mp4"
    if not fixture.exists():
        pytest.skip("no fixture beside this file")
    count, video, audio, seconds, fmt = unimovie.probe(fixture)
    assert count == 1
    assert video == 0
    assert audio == -1
    assert 0.9 < seconds < 1.1
    assert fmt == "isom"
    track = unimovie.track(fixture, video)
    assert track["codec"] == "avc1"
    assert (track["width"], track["height"]) == (64, 48)
