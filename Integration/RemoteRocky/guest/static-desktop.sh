#!/bin/sh

exec xterm \
    -fullscreen \
    -bg '#17212b' \
    -fg '#d8dee9' \
    -fa 'DejaVu Sans Mono' \
    -fs 16 \
    -title 'SwiftSpice deterministic baseline' \
    -e sh -c '
        clear
        printf "SwiftSpice remote performance fixture\n\n"
        printf "Resolution: 1280x720\n"
        printf "State: static baseline\n"
        printf "Animation: stopped\n\n"
        printf "Use the remote control script to start or reset the load.\n"
        exec tail -f /dev/null
    '
