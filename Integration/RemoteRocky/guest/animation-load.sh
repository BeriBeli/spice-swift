#!/bin/sh

exec setsid xterm \
    -fullscreen \
    -bg black \
    -fg white \
    -fa 'DejaVu Sans Mono' \
    -fs 12 \
    -title 'SwiftSpice deterministic animation' \
    -e /bin/sh -c \
        'echo "$$" > /run/perf-animation-generator.pid; exec /usr/local/bin/animation-generator.sh'
