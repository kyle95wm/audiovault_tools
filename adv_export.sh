#!/usr/bin/env bash
# avo_mp3_export.sh
# Batch export to MP3 192 kbps CBR (LAME), joint stereo disabled.
# - Prompts (or lets you specify) which audio stream to use when inputs have multiple tracks.
# - Uses audio-relative indices (0..N-1) that match `-map 0:a:N`.
# - Warns/skips if the chosen stream has >2 channels unless --force is used.
# - Supports processing a whole directory (non-recursive).

set -u

usage() {
  cat <<'EOF'
Usage:
  avo_mp3_export.sh [--force] [--dir DIR] [--stream N|--auto] [files...]

Options:
  --force        Proceed even if chosen audio stream has >2 channels (not recommended).
  --dir DIR      Process all media files in DIR (non-recursive).
  --stream N     Use audio-relative audio stream index N (0-based) for all files, skip prompts.
  --auto         Auto-pick a 2-ch stream if present; else use stream 0.
  -h|--help      Show this help.

Examples:
  avo_mp3_export.sh file1.wav file2.mp4
  avo_mp3_export.sh --dir /path/to/folder
  avo_mp3_export.sh --stream 2 "movie.mp4"
  avo_mp3_export.sh --auto --dir ./inputs
EOF
}

FORCE=0
DIR_MODE=""
STREAM_OVERRIDE=""
AUTO_PICK=0
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --dir)   DIR_MODE="$2"; shift 2 ;;
    --stream) STREAM_OVERRIDE="$2"; shift 2 ;;
    --auto)  AUTO_PICK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

# Expand directory contents if --dir provided
if [[ -n "${DIR_MODE}" ]]; then
  if [[ ! -d "$DIR_MODE" ]]; then
    echo "❌ Error: '$DIR_MODE' is not a directory." >&2; exit 1
  fi
  shopt -s nullglob
  for ext in wav aif aiff flac m4a mp4 mkv mov mka aac ac3 eac3 ogg opus wma; do
    for f in "$DIR_MODE"/*."$ext"; do FILES+=("$f"); done
  done
  shopt -u nullglob
fi

if [[ ${#FILES[@]} -eq 0 ]]; then usage; exit 1; fi

command -v ffprobe >/dev/null 2>&1 || { echo "❌ ffprobe required in PATH." >&2; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "❌ ffmpeg required in PATH."  >&2; exit 1; }

# Return: number of audio streams
count_audio_streams() {
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | wc -l | tr -d ' '
}

# Return: channels for audio-relative stream N
channels_for_stream() {
  local in="$1" idx="$2"
  ffprobe -v error -select_streams a:"$idx" -show_entries stream=channels -of default=nk=1:nw=1 "$in" 2>/dev/null
}

# Return: first 2ch audio-relative stream if present; else 0
pick_two_ch_or_zero() {
  local in="$1"
  local n
  n=$(count_audio_streams "$in")
  local i
  for (( i=0; i<n; i++ )); do
    local ch; ch="$(channels_for_stream "$in" "$i")"
    [[ "$ch" == "2" ]] && { echo "$i"; return; }
  done
  echo "0"
}

# Print a nice list of audio streams to STDERR using audio-relative indices
list_audio_streams() {
  local in="$1"
  echo "Available audio streams in: $in" >&2
  # Pull details of audio streams only
  ffprobe -v error -select_streams a \
    -show_entries stream=codec_name,channels,channel_layout,bit_rate:stream_tags=language,title \
    -of csv=p=0 "$in" \
    | awk -F',' '
      BEGIN { i=0 }
      {
        codec=$1; ch=$2; layout=$3; br=$4; lang=$5; title=$6
        if (br ~ /^[0-9]+$/) br = sprintf(" @ %d kbps", br/1000); else br=""
        if (lang=="" || lang=="N/A") lang=""; else lang=" [" lang "]"
        if (title=="" || title=="N/A") title=""; else title=" — " title
        if (layout=="" || layout=="N/A") layout=""; else layout=", " layout
        printf("  %d) %s, %s ch%s%s%s%s\n", i, codec, ch, layout, br, lang, title) >> "/dev/stderr"
        i++
      }
    '
}

select_stream_for_file() {
  local in="$1"
  local n_streams
  n_streams=$(count_audio_streams "$in")
  if [[ -n "$STREAM_OVERRIDE" ]]; then
    echo "$STREAM_OVERRIDE"; return
  fi
  if (( AUTO_PICK == 1 )); then
    pick_two_ch_or_zero "$in"; return
  fi
  if (( n_streams <= 1 )); then
    echo "0"; return
  fi

  list_audio_streams "$in"   # goes to stderr
  read -rp "Select audio stream index (default 0): " sel
  [[ -z "${sel:-}" ]] && sel="0"
  echo "$sel"
}

# Main loop
for input in "${FILES[@]}"; do
  if [[ ! -f "$input" ]]; then echo "⚠️  Skipping (not a file): $input" >&2; continue; fi

  stream_idx="$(select_stream_for_file "$input")"
  [[ "$stream_idx" =~ ^[0-9]+$ ]] || { echo "❌ Invalid stream index '$stream_idx' for $input" >&2; continue; }

  ch="$(channels_for_stream "$input" "$stream_idx" || echo "")"
  if [[ -z "$ch" ]]; then
    echo "⚠️  Couldn’t read channels for a:$stream_idx in $input — skipping." >&2
    continue
  fi

  if (( ch > 2 )) && (( FORCE == 0 )); then
    echo "🚫 $input (a:$stream_idx) has ${ch} channels. Skipping to avoid unintended surround→stereo fold-down." >&2
    echo "   Use --force if you *intend* to downmix." >&2
    continue
  elif (( ch > 2 )) && (( FORCE == 1 )); then
    echo "⚠️  Forcing export from ${ch}-ch source → stereo MP3 (not advisable)." >&2
  fi

  base="${input##*/}"
  name="${base%.*}"
  out="${name}.mp3"

  echo "🎧 Processing: $input  (a:$stream_idx, ${ch}ch)  →  $out" >&2
  # 192 kbps CBR, joint stereo disabled (Falconner preference)
  ffmpeg -y -i "$input" -map 0:a:"$stream_idx" -c:a libmp3lame -b:a 192k -joint_stereo 0 "$out"

  if [[ $? -eq 0 ]]; then
    echo "✅ Done: $out" >&2
  else
    echo "❌ Failed: $input" >&2
  fi
done
