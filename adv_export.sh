#!/usr/bin/env bash
# avo_mp3_export.sh
# Batch export to MP3 192 kbps CBR (LAME), joint stereo disabled.
# - Prompts (or lets you specify) which audio stream to use when inputs have multiple audio tracks.
# - Warns/skips if the chosen stream has >2 channels unless --force is used.

set -u

usage() {
  cat <<EOF
Usage:
  $0 [--force] [--dir DIR] [--stream N|--auto] [files...]

Options:
  --force        Proceed even if chosen audio stream has >2 channels (not recommended).
  --dir DIR      Process all media files in DIR (non-recursive).
  --stream N     Use audio stream index N (0-based) for all files, skip prompts.
  --auto         Auto-pick a 2-ch stream if present; else use stream 0.
  -h|--help      Show this help.

Examples:
  $0 file1.wav file2.mp4
  $0 --dir /path/to/folder
  $0 --stream 2 "movie.mp4"
  $0 --auto --dir ./inputs
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
    echo "❌ Error: '$DIR_MODE' is not a directory."; exit 1
  fi
  shopt -s nullglob
  for ext in wav aif aiff flac m4a mp4 mkv mov mka aac ac3 eac3 ogg opus wma; do
    for f in "$DIR_MODE"/*."$ext"; do FILES+=("$f"); done
  done
  shopt -u nullglob
fi

if [[ ${#FILES[@]} -eq 0 ]]; then usage; exit 1; fi
command -v ffprobe >/dev/null 2>&1 || { echo "❌ ffprobe required."; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "❌ ffmpeg required.";  exit 1; }

# Return: number of audio streams
count_audio_streams() {
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | wc -l | tr -d ' '
}

# Return: channels for audio stream N
channels_for_stream() {
  local in="$1" idx="$2"
  ffprobe -v error -select_streams a:"$idx" -show_entries stream=channels -of default=nk=1:nw=1 "$in" 2>/dev/null
}

# Return: best 2ch stream index if present; else 0
pick_two_ch_or_zero() {
  local in="$1"
  local idxs
  IFS=$'\n' read -r -d '' -a idxs < <(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in" && printf '\0')
  for i in "${idxs[@]}"; do
    local ch="$(channels_for_stream "$in" "$i")"
    [[ "$ch" == "2" ]] && { echo "$i"; return; }
  done
  echo "0"
}

# Pretty-list audio streams for prompt
list_audio_streams() {
  local in="$1"
  echo "Available audio streams in: $in"
  ffprobe -v error -select_streams a \
    -show_entries stream=index,codec_name,channels,channel_layout,bit_rate \
    -show_entries stream_tags=language,title \
    -of csv=p=0 "$in" \
    | awk -F',' '{
        idx=$1; codec=$2; ch=$3; layout=$4; br=$5; lang=$6; title=$7;
        if (br=="N/A" || br=="") br=""; else br=sprintf(" @ %.0f kbps", br/1000);
        if (lang=="N/A" || lang=="") lang=""; else lang=" ["lang"]";
        if (title=="N/A" || title=="") title=""; else title=" — "title;
        printf("  %s) a:%s — %s, %s ch%s%s%s\n", idx, idx, codec, ch, br, lang, title);
      }'
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

  list_audio_streams "$in"
  read -rp "Select audio stream index (default 0): " sel
  [[ -z "${sel:-}" ]] && sel="0"
  echo "$sel"
}

for input in "${FILES[@]}"; do
  if [[ ! -f "$input" ]]; then echo "⚠️  Skipping (not a file): $input"; continue; fi

  stream_idx="$(select_stream_for_file "$input")"
  # Validate numeric
  [[ "$stream_idx" =~ ^[0-9]+$ ]] || { echo "❌ Invalid stream index '$stream_idx' for $input"; continue; }

  ch="$(channels_for_stream "$input" "$stream_idx" || echo "")"
  if [[ -z "$ch" ]]; then
    echo "⚠️  Couldn’t read channels for a:$stream_idx in $input — skipping."
    continue
  fi

  if (( ch > 2 )) && (( FORCE == 0 )); then
    echo "🚫 $input (a:$stream_idx) has ${ch} channels. Skipping to avoid unintended surround→stereo fold-down."
    echo "   Use --force if you *intend* to downmix."
    continue
  elif (( ch > 2 )) && (( FORCE == 1 )); then
    echo "⚠️  Forcing export from ${ch}-ch source → stereo MP3 (not advisable)."
  fi

  base="${input##*/}"
  name="${base%.*}"
  out="${name}.mp3"

  echo "🎧 Processing: $input  (a:$stream_idx, ${ch}ch)  →  $out"
  ffmpeg -y -i "$input" -map 0:a:"$stream_idx" -c:a libmp3lame -b:a 192k -joint_stereo 0 "$out"

  if [[ $? -eq 0 ]]; then
    echo "✅ Done: $out"
  else
    echo "❌ Failed: $input"
  fi
done
