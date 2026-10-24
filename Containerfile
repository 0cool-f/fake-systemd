# SPDX-License-Identifier: GPL-3.0-or-later
FROM docker.io/library/alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS zig

ARG ZIG_VERSION
ARG ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

RUN apk add --no-cache curl minisign tar xz

RUN set -eu; \
    test -n "$ZIG_VERSION"; \
    arch="$(uname -m)"; \
    name="zig-${arch}-linux-${ZIG_VERSION}"; \
    url="https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz"; \
    curl -fsSLo /tmp/zig.tar.xz "$url"; \
    curl -fsSLo /tmp/zig.tar.xz.minisig "$url.minisig"; \
    minisign -Vm /tmp/zig.tar.xz -x /tmp/zig.tar.xz.minisig -P "$ZIG_PUBKEY"; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1

FROM cgr.dev/chainguard/wolfi-base@sha256:13ecca0cd6ee68809c95676fbe2b5bd65878ab8974dab5059ea6dc4db4de6909

COPY --from=zig /opt/zig /opt/zig

ENV PATH=/opt/zig:$PATH \
    ZIG_GLOBAL_CACHE_DIR=/src/.zig-cache/global

WORKDIR /src
