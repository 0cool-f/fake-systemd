#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Renders packaging/aur/fake-systemd-bin/PKGBUILD.in to stdout; fails if a placeholder is left.
# Env: VERSION SHA256_X86_64 SHA256_AARCH64 OWNER MAINTAINER, optional BASE_URL (release download URL).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
: "${VERSION:?}" "${SHA256_X86_64:?}" "${SHA256_AARCH64:?}" "${OWNER:?}" "${MAINTAINER:?}"
base_url=${BASE_URL:-https://github.com/$OWNER/fake-systemd/releases/download/v$VERSION}

rendered=$(sed \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SHA256_X86_64@|$SHA256_X86_64|g" \
    -e "s|@SHA256_AARCH64@|$SHA256_AARCH64|g" \
    -e "s|@OWNER@|$OWNER|g" \
    -e "s|@MAINTAINER@|$MAINTAINER|g" \
    -e "s|@BASE_URL@|$base_url|g" \
    "$here/fake-systemd-bin/PKGBUILD.in")

if printf '%s\n' "$rendered" | grep -q '@[A-Z0-9_]*@'; then
    echo "unreplaced placeholder in rendered PKGBUILD" >&2
    exit 1
fi
printf '%s\n' "$rendered"
