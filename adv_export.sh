#!/usr/bin/env bash
# avo_mp3_export.sh
# Batch export to MP3 with bitrate chosen from source audio bitrate.
# - Prompts (or lets you specify) which audio stream to use when inputs have multiple tracks.
# - Warns/skips if chosen stream has >2 ch unless --force is used.
# - If --force and layout is 5.1, applies a controlled downmix pan matrix (optional LFE blend with --lfe).
# - Supports processing a whole directory (non-recursive).

set -u

usage() {
  cat <<'EOF'
Usage:
  avo_mp3_export.sh [--force] [--lfe] [--dir DIR] [--stream N|--auto] [files...]

Options:
  --force        Proceed even if chosen audio stream has >2 channels (not recommended).
  --lfe          When downmixing 5.1 under --force, include a small amount of LFE in the fold.
  --dir DIR      Process all media files in DIR (non-recursive).
  --stream N     Use audio-relative stream index N (0-based) for all files, skip prompts.
  --auto         Auto-pick a 2-ch stream if present; else use stream 0.
  -h|--help      Show this help.

Examples:
  avo_mp3_export.sh file1.wav file2.mp4
  avo_mp3_export.sh --dir /path/to/folder
  avo_mp3_export.sh --auto --dir ./inputs
  avo_mp3_export.sh --stream 2 "Show S01E01.mp4"
  avo_mp3_export.sh --force --lfe "Movie 5.1.mkv"
EOF
}

FORCE=0
INCLUDE_LFE=0
DIR_MODE=""
STREAM_OVERRIDE=""
AUTO_PICK=0
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --lfe)   INCLUDE_LFE=1; shift ;;
    --dir)   DIR_MODE="$2"; shift 2 ;;
    --stream) STREAM_OVERRIDE="$2"; shift 2 ;;
    --auto)  AUTO_PICK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [[ -n "${DIR_MODE}" ]]; then
  if [[ ! -d "$DIR_MODE" ]]; then
    echo "❌ Error: '$DIR_MODE' is not a directory." >&2
    exit 1
  fi
  shopt -s nullglob
  for ext in wav aif aiff flac m4a mp4 mkv mov mka aac ac3 eac3 ogg opus wma; do
    for f in "$DIR_MODE"/*."$ext"; do
      FILES+=("$f")
    done
  done
  shopt -u nullglob
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  usage
  exit 1
fi

command -v ffprobe >/dev/null 2>&1 || { echo "❌ ffprobe required in PATH." >&2; exit 1; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "❌ ffmpeg required in PATH."  >&2; exit 1; }

count_audio_streams() {
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | wc -l | tr -d ' '
}

channels_for_stream() {
  local in="$1" idx="$2"
  ffprobe -v error -select_streams a:"$idx" -show_entries stream=channels -of default=nk=1:nw=1 "$in" 2>/dev/null
}

layout_for_stream() {
  local in="$1" idx="$2"
  ffprobe -v error -select_streams a:"$idx" -show_entries stream=channel_layout -of default=nk=1:nw=1 "$in" 2>/dev/null
}

stream_bitrate_kbps() {
  local in="$1" idx="$2"
  local br

  br="$(ffprobe -v error -select_streams a:"$idx" \
    -show_entries stream=bit_rate \
    -of default=nk=1:nw=1 "$in" 2>/dev/null | head -n1)"

  if [[ -z "$br" || "$br" == "N/A" ]]; then
    br="$(ffprobe -v error -show_entries format=bit_rate \
      -of default=nk=1:nw=1 "$in" 2>/dev/null | head -n1)"
  fi

  [[ "$br" =~ ^[0-9]+$ ]] || { echo ""; return; }
  echo $(( br / 1000 ))
}

choose_mp3_bitrate() {
  local src_kbps="$1"

  if [[ -z "$src_kbps" || ! "$src_kbps" =~ ^[0-9]+$ ]]; then
    echo "192k"
    return
  fi

  if (( src_kbps >= 192 )); then
    echo "192k"
  elif (( src_kbps >= 160 )); then
    echo "160k"
  elif (( src_kbps >= 128 )); then
    echo "128k"
  elif (( src_kbps >= 96 )); then
    echo "96k"
  else
    echo "96k"
  fi
}

pick_two_ch_or_zero() {
  local in="$1"
  local n i ch
  n=$(count_audio_streams "$in")
  for (( i=0; i<n; i++ )); do
    ch="$(channels_for_stream "$in" "$i")"
    [[ "$ch" == "2" ]] && { echo "$i"; return; }
  done
  echo "0"
}

list_audio_streams() {
  local in="$1"
  echo "Available audio streams in: $in" >&2
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
    echo "$STREAM_OVERRIDE"
    return
  fi
  if (( AUTO_PICK == 1 )); then
    pick_two_ch_or_zero "$in"
    return
  fi
  if (( n_streams <= 1 )); then
    echo "0"
    return
  fi

  list_audio_streams "$in"
  read -rp "Select audio stream index (default 0): " sel
  [[ -z "${sel:-}" ]] && sel="0"
  echo "$sel"
}

build_pan_filter_5_1() {
  local with_lfe="$1"
  if (( with_lfe == 1 )); then
    echo "pan=stereo|FL=0.707*FL+0.707*FC+0.5*BL+0.5*SL+0.35*LFE|FR=0.707*FR+0.707*FC+0.5*BR+0.5*SR+0.35*LFE"
  else
    echo "pan=stereo|FL=0.707*FL+0.707*FC+0.5*BL+0.5*SL|FR=0.707*FR+0.707*FC+0.5*BR+0.5*SR"
  fi
}

for input in "${FILES[@]}"; do
  if [[ ! -f "$input" ]]; then
    echo "⚠️  Skipping (not a file): $input" >&2
    continue
  fi

  stream_idx="$(select_stream_for_file "$input")"
  [[ "$stream_idx" =~ ^[0-9]+$ ]] || {
    echo "❌ Invalid stream index '$stream_idx' for $input" >&2
    continue
  }

  ch="$(channels_for_stream "$input" "$stream_idx" || echo "")"
  if [[ -z "$ch" ]]; then
    echo "⚠️  Couldn’t read channels for a:$stream_idx in $input — skipping." >&2
    continue
  fi

  lay="$(layout_for_stream "$input" "$stream_idx" || echo "")"
  src_kbps="$(stream_bitrate_kbps "$input" "$stream_idx")"
  mp3_bitrate="$(choose_mp3_bitrate "$src_kbps")"

  if [[ -n "$src_kbps" ]]; then
    echo "ℹ️  Source bitrate for a:$stream_idx appears to be ${src_kbps} kbps; using MP3 CBR ${mp3_bitrate}." >&2
  else
    echo "ℹ️  Could not detect source bitrate for a:$stream_idx; defaulting to MP3 CBR ${mp3_bitrate}." >&2
  fi

  PAN_FILTER=""
  if (( ch > 2 )); then
    if (( FORCE == 0 )); then
      echo "🚫 $input (a:$stream_idx) has ${ch} channels. Skipping to avoid unintended surround→stereo fold-down." >&2
      echo "   Use --force if you intend to downmix." >&2
      continue
    else
      if [[ "$lay" == 5.1* || "$lay" == *"5.1"* || "$ch" == "6" ]]; then
        PAN_FILTER="$(build_pan_filter_5_1 "$INCLUDE_LFE")"
        echo "⚠️  Forcing export from 5.1 (${lay:-unknown}) → stereo MP3 with controlled pan matrix." >&2
        (( INCLUDE_LFE == 1 )) && echo "   LFE included at a low level." >&2
      else
        echo "⚠️  Forcing export from ${ch}-ch (${lay:-unknown}) → stereo MP3 with FFmpeg default downmix (no custom matrix available)." >&2
      fi
    fi
  fi

  base="${input##*/}"
  name="${base%.*}"
  name="$(printf '%s' "$name" | sed -E 's/_[Ss][Tt][Ee][Rr][Ee][Oo]$//')"
  out="${name}.mp3"

  echo "🎧 Processing: $input  (a:$stream_idx, ${ch}ch${lay:+, $lay})  →  $out" >&2

  map=(-map "0:a:${stream_idx}")
  audio=(-c:a libmp3lame -b:a "$mp3_bitrate" -joint_stereo 0)

  if [[ -n "$PAN_FILTER" ]]; then
    audio=(-af "$PAN_FILTER" "${audio[@]}")
  fi

  ffmpeg -y -i "$input" "${map[@]}" "${audio[@]}" "$out"

  if [[ $? -eq 0 ]]; then
    echo "✅ Done: $out" >&2
  else
    echo "❌ Failed: $input" >&2
  fi
done
