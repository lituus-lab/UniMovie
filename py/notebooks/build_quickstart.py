# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Author py/notebooks/quickstart.ipynb, then execute it so the committed file
carries real outputs for GitHub to render. Run from the repo root:

    python3 py/notebooks/build_quickstart.py

CI re-executes the notebook against an installed wheel; this script only
regenerates it after an API change."""
import os

import nbformat as nbf
from nbclient import NotebookClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "quickstart.ipynb")

CELLS = [
    ("md", "# unimovie — quickstart\n\n"
           "Demultiplexing for video containers: what is inside a file, "
           "without decoding any of it."),
    ("code", "import os\nimport unimovie\n\n"
             "FIXTURE = os.path.join('tests', 'fixtures', 'av.mp4')\n"
             "unimovie.version()"),
    ("md", "`probe` gives the shape in five values: how many tracks, which "
           "is the first video and audio one — `-1` when there is none, "
           "because a file without sound is an ordinary file — the playing "
           "time, and the container. An ISO base media file answers with the "
           "major brand it claims, `isom` here rather than `mp4`, since that "
           "is what the file itself says."),
    ("code", "unimovie.probe(FIXTURE)"),
    ("md", "`tracks` lists every track. `codec` is the container's own "
           "four-character code rather than a friendlier name: that is what "
           "a decoder backend is registered under, and `avc1` and `avc3` "
           "differ in where their parameter sets live."),
    ("code", "unimovie.tracks(FIXTURE)"),
    ("md", "`rotation` counts clockwise degrees. `ffprobe` reports the same "
           "transformation matrix counting anticlockwise, so a file it calls "
           "`rotation=90` reads here as `270`. Both describe the same matrix; "
           "the sign is the trap when migrating off `ffprobe`."),
    ("code", "rotated = os.path.join('tests', 'fixtures', 'rotated.mov')\n"
             "unimovie.track(rotated, 0)"),
    ("md", "Nothing above decoded a frame. Turning a coded sample into pixels "
           "belongs to a backend the application registers, which is what "
           "keeps a patented decoder out of this library.\n\n"
           "See `include/UniMovie.h`, and the book for the full picture."),
]


def main():
    nb = nbf.v4.new_notebook()
    nb.cells = [
        nbf.v4.new_markdown_cell(src) if kind == "md" else nbf.v4.new_code_cell(src)
        for kind, src in CELLS
    ]
    nb.metadata["kernelspec"] = {
        "display_name": "Python 3",
        "language": "python",
        "name": "python3",
    }
    # Execute from the repo root, never from py/: there, `import unimovie`
    # would resolve to the py/unimovie source tree instead of the installed
    # package, and the notebook would stop testing what it claims to test.
    NotebookClient(nb, timeout=120, kernel_name="python3",
                   resources={"metadata": {"path": ROOT}}).execute()
    with open(OUT, "w", encoding="utf-8") as f:
        nbf.write(nb, f)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
