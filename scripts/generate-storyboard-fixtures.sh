#!/bin/bash
set -euo pipefail
OUT="${1:?Supply a fresh absolute output directory.}"
[[ "$OUT" == /* && ! -e "$OUT" ]]
mkdir -p "$OUT"
FFMPEG="${BLOOM_FIXTURE_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
"$FFMPEG" -version > "$OUT/ffmpeg-version.txt"
sw_vers > "$OUT/macos-version.txt"
/usr/bin/say -v Samantha -o "$OUT/speech.wav" --file-format=WAVE --data-format=LEI16@16000 'The clock struck seven. Mara opened the blue door.'
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i 'color=red:s=160x96:r=24:d=2.75' -f lavfi -i 'color=blue:s=160x96:r=24:d=2.75' -f lavfi -i 'color=green:s=160x96:r=24:d=2.5' -i "$OUT/speech.wav" -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v];[3:a]adelay=1000:all=1,apad,atrim=duration=8[a]' -map '[v]' -map '[a]' -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart "$OUT/scene-speech.mp4"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i 'color=red:s=64x48:r=4:d=8' -itsoffset 1 -i "$OUT/speech.wav" -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart "$OUT/offset-audio.mp4"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i 'color=red:s=64x48:r=4:d=70' -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/static-long.mp4"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i 'color=red:s=64x48:r=1:d=9' -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/static-sparse.mp4"
(cd "$OUT" && shasum -a 256 *.wav *.mp4 > source-files.sha256)
