#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Lints the GitHub workflows with actionlint. Usage: tests/lint-workflows.sh   (CONTAINER_ENGINE overrides podman)
set -eu

engine=${CONTAINER_ENGINE:-podman}
root=$(cd "$(dirname "$0")/.." && pwd)

exec "$engine" run --rm -v "$root:/repo:ro,Z" -w /repo \
    docker.io/rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
