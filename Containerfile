# SPDX-License-Identifier: GPL-3.0-or-later
FROM docker.io/library/alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS zig

ARG ZIG_VERSION
ARG ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

RUN apk add --no-cache curl minisign tar xz

RUN set -eu; \
    test -n "$ZIG_VERSION"; \
    arch="$(uname -m)"; \
    name="zig-${arch}-linux-${ZIG_VERSION}"; \
    url="https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz"; \
    curl -fsSL --retry 5 --retry-all-errors -o /tmp/zig.tar.xz "$url"; \
    curl -fsSL --retry 5 --retry-all-errors -o /tmp/zig.tar.xz.minisig "$url.minisig"; \
    minisign -Vm /tmp/zig.tar.xz -x /tmp/zig.tar.xz.minisig -P "$ZIG_PUBKEY"; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1

FROM cgr.dev/chainguard/wolfi-base@sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b

COPY --from=zig /opt/zig /opt/zig

ENV PATH=/opt/zig:$PATH \
    ZIG_GLOBAL_CACHE_DIR=/src/.zig-cache/global

WORKDIR /src
