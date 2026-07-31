#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
fixture_dir="$repository_dir/Tests/SpiceVideoToolboxTests/Fixtures"
temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT HUP INT TERM

mkdir -p "$fixture_dir"

generate_fixture() {
    name=$1
    codec=$2
    source=$3
    profile=$4
    encoded="$temporary_dir/$name.annexb"
    decoded="$temporary_dir/$name.bgra"

    if [ "$codec" = "h264" ]; then
        if [ -n "$profile" ]; then
            profile_arguments="-profile:v $profile"
        else
            profile_arguments=""
        fi
        # shellcheck disable=SC2086
        ffmpeg -hide_banner -loglevel error \
            -f lavfi -i "$source=size=128x128:rate=1" \
            -frames:v 1 -pix_fmt yuv420p -c:v libx264 -preset veryslow \
            -tune zerolatency -level:v 3.1 $profile_arguments \
            -x264-params 'keyint=1:min-keyint=1:scenecut=0:repeat-headers=1' \
            -bsf:v 'filter_units=remove_types=6' -f h264 -y "$encoded"
    else
        ffmpeg -hide_banner -loglevel error \
            -f lavfi -i "$source=size=128x128:rate=1" \
            -frames:v 1 -pix_fmt yuv420p -c:v libx265 -preset veryslow \
            -level:v 3.1 \
            -x265-params 'keyint=1:min-keyint=1:scenecut=0:repeat-headers=1:log-level=error' \
            -bsf:v 'filter_units=remove_types=39' -f hevc -y "$encoded"
    fi

    ffmpeg -hide_banner -loglevel error -i "$encoded" \
        -frames:v 1 -pix_fmt bgra -f rawvideo -y "$decoded"

    encoded_base64=$(base64 -i "$encoded" | tr -d '\n')
    decoded_base64=$(base64 -i "$decoded" | tr -d '\n')
    generator=$(ffmpeg -version | sed -n '1s/ Copyright.*//p')
    cat > "$fixture_dir/$name.json" <<EOF
{
  "generator": "$generator software $codec encode and decode; source=$source; 128x128 yuv420p; SEI removed",
  "codec": "$codec",
  "width": 128,
  "height": 128,
  "annexBBase64": "$encoded_base64",
  "expectedBGRABase64": "$decoded_base64"
}
EOF
}

generate_fixture h264-high-128x128 h264 testsrc2 ""
generate_fixture h264-baseline-128x128 h264 smptebars baseline
generate_fixture h265-main-128x128 h265 testsrc2 ""
