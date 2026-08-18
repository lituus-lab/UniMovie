# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniMovie build config. Minimal: the template has no arch-specific paths.
# when defined(amd64) and not defined(scalarUniMovie):
#   switch("passC", "-ffp-contract=off")

# UniImage sits beside this repo in the lituus-lab checkout; the box reader
# comes from there rather than being written twice.
switch("path", "../UniImage/src")
