#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regenerates tests/timers/oracle.txt (and the zone files in tests/timers/zones) from real
# systemd-analyze running in a Debian 13 container (systemd 257).
#
#   tests/timers/gen.sh            regenerate oracle.txt and zones/
#   ORACLE_IMAGE=... TRANSCRIPT_DIR=... tests/timers/gen.sh
#
# ORACLE_IMAGE must be debian:13 with the `systemd` package (and tzdata) installed.
# oracle.txt has one tab-separated record per expression and context:
#   zone  base_unix_seconds  expression  normalized-or-ERR  elapse1,elapse2,...  (unix seconds)
# Sub-second elapses are printed truncated to the second by systemd-analyze.
set -euo pipefail

if [ "${INSIDE:-}" = 1 ]; then
    ctxs=()
    transcript=${TRANSCRIPT:-/dev/null}
    : >"$transcript"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        '' | '#'*) continue ;;
        '@clear')
            ctxs=()
            continue
            ;;
        '@ctx '*)
            read -r _ zone day time <<<"$line"
            ctxs+=("$zone|$(date -u -d "$day $time" +%s)")
            continue
            ;;
        esac
        for ctx in "${ctxs[@]}"; do
            zone=${ctx%%|*}
            base=${ctx##*|}
            out=$(TZ=$zone systemd-analyze calendar --iterations=5 --base-time="@$base" "$line" 2>&1 </dev/null) || true
            {
                printf '### TZ=%s base=@%s expr=%s\n%s\n' "$zone" "$base" "$line" "$out"
            } >>"$transcript"
            norm=ERR
            elapses=()
            pending=
            while IFS= read -r l; do
                case "$l" in
                *'Normalized form: '*) norm=${l#*Normalized form: } ;;
                *'Next elapse: never') ;;
                *'Next elapse: '* | *'Iteration #'*)
                    pending=${l#*: }
                    elapses+=("$pending")
                    ;;
                *'(in UTC): '*) elapses[${#elapses[@]} - 1]=${l#*(in UTC): } ;;
                esac
            done <<<"$out"
            secs=()
            for e in "${elapses[@]}"; do
                # "Sat 2026-03-28 13:20:00 UTC" -> unix seconds
                stamp=${e#* }
                stamp=${stamp% *}
                secs+=("$(date -u -d "$stamp" +%s)")
            done
            joined=$(
                IFS=,
                echo "${secs[*]:-}"
            )
            printf '%s\t%s\t%s\t%s\t%s\n' "$zone" "$base" "$line" "$norm" "$joined"
        done
    done
    exit 0
fi

dir=$(cd "$(dirname "$0")" && pwd)
image=${ORACLE_IMAGE:-localhost/sysd-probe}
tdir=${TRANSCRIPT_DIR:-}
mounts=(-v "$dir:/w:ro,Z")
env=(-e INSIDE=1)
if [ -n "$tdir" ]; then
    mkdir -p "$tdir"
    mounts+=(-v "$tdir:/out:Z")
    env+=(-e TRANSCRIPT=/out/calendar-transcript.txt)
fi
podman run -i --rm "${mounts[@]}" "${env[@]}" "$image" bash /w/gen.sh <"$dir/exprs.txt" >"$dir/oracle.txt"

mkdir -p "$dir/zones"
for z in Europe/Rome America/New_York Asia/Tokyo Australia/Lord_Howe America/Havana Asia/Kolkata UTC; do
    podman run --rm "$image" cat "/usr/share/zoneinfo/$z" >"$dir/zones/$(echo "$z" | tr / _)"
done
wc -l "$dir/oracle.txt"
