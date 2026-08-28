#!/bin/sh

exec xterm \
    -fullscreen \
    -bg '#17212b' \
    -fg '#d8dee9' \
    -fa 'DejaVu Sans Mono' \
    -fs 16 \
    -title 'SwiftSpice deterministic baseline' \
    -e /usr/local/bin/input-marker-renderer.sh workload static
