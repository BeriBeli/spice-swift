#!/bin/sh

exec xterm \
    -fullscreen \
    -bg black \
    -fg white \
    -fa 'DejaVu Sans Mono' \
    -fs 12 \
    -title 'SwiftSpice deterministic animation' \
    -e /usr/local/bin/animation-generator.sh
