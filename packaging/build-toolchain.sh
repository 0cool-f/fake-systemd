#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the `fake-systemd-build` toolchain image (Zig version from .zig-version) unless it is current.
# Usage: packaging/build-toolchain.sh   (CONTAINER_ENGINE and IMAGE_CACHE_DIR as in tests/e2e/lib/image.sh)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
exec "$root/tests/e2e/lib/image.sh" fake-systemd-build "$root" --build-arg "ZIG_VERSION=$(cat "$root/.zig-version")"
