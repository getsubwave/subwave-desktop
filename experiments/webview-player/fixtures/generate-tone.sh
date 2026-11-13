#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$script_dir/tone.mp3"}

ffmpeg \
  -hide_banner \
  -loglevel error \
  -y \
  -f lavfi \
  -i 'sine=frequency=440:sample_rate=44100' \
  -t 30 \
  -map_metadata -1 \
  -c:a libmp3lame \
  -b:a 128k \
  -write_xing 0 \
  -id3v2_version 0 \
  "$output"

printf '%s\n' "$output"
