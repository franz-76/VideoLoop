#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-/opt/media}"
DST_DIR="${2:-/opt/media_optimized}"

WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"

FPS="${FPS:-25}"
IMAGE_DURATION="${IMAGE_DURATION:-10}"
CRF="${CRF:-23}"

mkdir -p "$DST_DIR"

command -v ffmpeg >/dev/null 2>&1 || {
  echo "Errore: ffmpeg non installato."
  echo "Installa con: sudo apt update && sudo apt install ffmpeg"
  exit 1
}

is_image() {
  case "${1,,}" in
    *.jpg|*.jpeg|*.png|*.bmp|*.webp) return 0 ;;
    *) return 1 ;;
  esac
}

is_video() {
  case "${1,,}" in
    *.mp4|*.mov|*.m4v|*.mkv|*.avi|*.webm) return 0 ;;
    *) return 1 ;;
  esac
}

safe_name() {
  local name="$1"
  name="${name%.*}"
  name="$(echo "$name" | tr ' ' '_' | tr -cd '[:alnum:]_.-')"
  echo "$name"
}

convert_image() {
  local input="$1"
  local base output

  base="$(safe_name "$(basename "$input")")"
  output="$DST_DIR/${base}.mp4"

  echo "IMAGE -> $output"

  ffmpeg -hide_banner -loglevel warning -y \
    -loop 1 \
    -i "$input" \
    -t "$IMAGE_DURATION" \
    -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:black,fps=${FPS},format=yuv420p" \
    -c:v libx264 \
    -preset veryfast \
    -profile:v high \
    -level 4.0 \
    -crf "$CRF" \
    -movflags +faststart \
    -an \
    "$output"
}

convert_video() {
  local input="$1"
  local base output

  base="$(safe_name "$(basename "$input")")"
  output="$DST_DIR/${base}.mp4"

  echo "VIDEO -> $output"

  ffmpeg -hide_banner -loglevel warning -y \
    -i "$input" \
    -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:black,fps=${FPS},format=yuv420p" \
    -c:v libx264 \
    -preset veryfast \
    -profile:v high \
    -level 4.0 \
    -crf "$CRF" \
    -c:a aac \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    -movflags +faststart \
    "$output"
}

echo "Sorgente:     $SRC_DIR"
echo "Destinazione: $DST_DIR"
echo "Formato:      ${WIDTH}x${HEIGHT}, ${FPS} fps, H.264, yuv420p"
echo "Durata foto:  ${IMAGE_DURATION}s"
echo

shopt -s nullglob

count=0

while IFS= read -r -d '' file; do
  if is_image "$file"; then
    convert_image "$file"
    count=$((count + 1))
  elif is_video "$file"; then
    convert_video "$file"
    count=$((count + 1))
  else
    echo "SKIP -> $file"
  fi
done < <(find "$SRC_DIR" -maxdepth 1 -type f -print0 | sort -z)

echo
echo "Completato. File processati: $count"
echo "Output in: $DST_DIR"
