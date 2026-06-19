#!/usr/bin/env bash
# adv_export.sh
# Batch export to MP3 with overview/confirmation.
# Bitrate rules:
# - Source >= 192 kbps -> 192k MP3
# - Lower bitrates are matched to standard buckets:
#   160 -> 160k, 128 -> 128k, 96 -> 96k, 64 -> 64k, 32 -> 32k
# - Near misses like 127 kbps are rounded to the intended bucket.

set -u

usage() {
  cat <<'EOF'
Usage:
  adv_export.sh [--force] [--lfe] [--dir DIR] [--stream N|--auto] [files...]

Options:
  --force        Proceed even if chosen audio stream has >2 channels.
  --lfe          When downmixing 5.1 under --force, include a small amount of LFE.
  --dir DIR      Process all media files in DIR, non-recursive.
  --stream N     Use audio-relative stream index N, 0-based.
  --auto         Auto-pick a 2-ch stream if present; else use stream 0.
  -h|--help      Show this help.
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
    --lfe) INCLUDE_LFE=1; shift ;;
    --dir) DIR_MODE="$2"; shift 2 ;;
    --stream) STREAM_OVERRIDE="$2"; shift 2 ;;
    --auto) AUTO_PICK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [[ -n "$DIR_MODE" ]]; then
  if [[ ! -d "$DIR_MODE" ]]; then
    echo "ERROR: '$DIR_MODE' is not a directory." >&2
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

command -v ffprobe >/dev/null 2>&1 || { echo "ERROR: ffprobe required in PATH." >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg required in PATH." >&2; exit 1; }

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
  local src_kbps="${1:-0}"

  if [[ ! "$src_kbps" =~ ^[0-9]+$ ]]; then
    echo "128k"
    return
  fi

  if (( src_kbps >= 192 )); then
    echo "192k"
  elif (( src_kbps >= 152 )); then
    echo "160k"
  elif (( src_kbps >= 120 )); then
    echo "128k"
  elif (( src_kbps >= 88 )); then
    echo "96k"
  elif (( src_kbps >= 56 )); then
    echo "64k"
  else
    echo "32k"
  fi
}

pick_two_ch_or_zero() {
  local in="$1"
  local n i ch
  n="$(count_audio_streams "$in")"

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
        if (title=="" || title=="N/A") title=""; else title=" - " title
        if (layout=="" || layout=="N/A") layout=""; else layout=", " layout
        printf("  %d) %s, %s ch%s%s%s%s\n", i, codec, ch, layout, br, lang, title) >> "/dev/stderr"
        i++
      }
    '
}

select_stream_for_file() {
  local in="$1"
  local n_streams sel
  n_streams="$(count_audio_streams "$in")"

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

INPUTS=()
STREAMS=()
CHANNELS=()
LAYOUTS=()
SOURCE_KBPS=()
MP3_BITRATES=()
OUTPUTS=()
PAN_FILTERS=()
SKIP_REASONS=()

echo "Scanning files..." >&2

for input in "${FILES[@]}"; do
  stream_idx=""
  ch=""
  lay=""
  src_kbps=""
  mp3_bitrate=""
  out=""
  pan_filter=""
  skip_reason=""

  if [[ ! -f "$input" ]]; then
    skip_reason="not a file"
  else
    stream_idx="$(select_stream_for_file "$input")"

    if [[ ! "$stream_idx" =~ ^[0-9]+$ ]]; then
      skip_reason="invalid stream index: $stream_idx"
    else
      ch="$(channels_for_stream "$input" "$stream_idx" || echo "")"

      if [[ -z "$ch" ]]; then
        skip_reason="could not read channel count"
      else
        lay="$(layout_for_stream "$input" "$stream_idx" || echo "")"
        src_kbps="$(stream_bitrate_kbps "$input" "$stream_idx")"
        mp3_bitrate="$(choose_mp3_bitrate "$src_kbps")"

        if (( ch > 2 )); then
          if (( FORCE == 0 )); then
            skip_reason="${ch} channels; use --force to downmix"
          else
            if [[ "$lay" == 5.1* || "$lay" == *"5.1"* || "$ch" == "6" ]]; then
              pan_filter="$(build_pan_filter_5_1 "$INCLUDE_LFE")"
            fi
          fi
        fi

        base="${input##*/}"
        name="${base%.*}"
        name="$(printf '%s' "$name" | sed -E 's/_[Ss][Tt][Ee][Rr][Ee][Oo]$//')"
        out="${name}.mp3"
      fi
    fi
  fi

  INPUTS+=("$input")
  STREAMS+=("$stream_idx")
  CHANNELS+=("$ch")
  LAYOUTS+=("$lay")
  SOURCE_KBPS+=("$src_kbps")
  MP3_BITRATES+=("$mp3_bitrate")
  OUTPUTS+=("$out")
  PAN_FILTERS+=("$pan_filter")
  SKIP_REASONS+=("$skip_reason")
done

echo
echo "Overview"
echo "--------"

convert_count=0
skip_count=0

for (( i=0; i<${#INPUTS[@]}; i++ )); do
  input="${INPUTS[$i]}"
  stream_idx="${STREAMS[$i]}"
  ch="${CHANNELS[$i]}"
  lay="${LAYOUTS[$i]}"
  src_kbps="${SOURCE_KBPS[$i]}"
  mp3_bitrate="${MP3_BITRATES[$i]}"
  out="${OUTPUTS[$i]}"
  skip_reason="${SKIP_REASONS[$i]}"

  if [[ -n "$skip_reason" ]]; then
    echo "SKIP: $input"
    echo "      Reason: $skip_reason"
    ((skip_count++))
  else
    src_display="${src_kbps:-unknown}"
    lay_display="${lay:-unknown}"

    echo "OK:   $input"
    echo "      Stream: a:$stream_idx, ${ch}ch, layout: $lay_display"
    echo "      Bitrate: source ${src_display} kbps -> MP3 CBR ${mp3_bitrate}"
    echo "      Output: $out"

    if [[ -n "${PAN_FILTERS[$i]}" ]]; then
      echo "      Downmix: controlled 5.1 -> stereo pan matrix"
    elif (( ch > 2 )); then
      echo "      Downmix: FFmpeg default surround -> stereo"
    fi

    ((convert_count++))
  fi

  echo
done

echo "Ready to convert: $convert_count file(s)"
echo "Will skip:        $skip_count file(s)"
echo

if (( convert_count == 0 )); then
  echo "Nothing to convert."
  exit 1
fi

read -rp "Start conversion? [y/N] " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *)
    echo "Cancelled."
    exit 0
    ;;
esac

for (( i=0; i<${#INPUTS[@]}; i++ )); do
  input="${INPUTS[$i]}"
  stream_idx="${STREAMS[$i]}"
  ch="${CHANNELS[$i]}"
  lay="${LAYOUTS[$i]}"
  src_kbps="${SOURCE_KBPS[$i]}"
  mp3_bitrate="${MP3_BITRATES[$i]}"
  out="${OUTPUTS[$i]}"
  PAN_FILTER="${PAN_FILTERS[$i]}"
  skip_reason="${SKIP_REASONS[$i]}"

  if [[ -n "$skip_reason" ]]; then
    echo "WARNING: Skipping: $input ($skip_reason)" >&2
    continue
  fi

  if [[ -n "$src_kbps" ]]; then
    echo "INFO: Source bitrate for a:$stream_idx appears to be ${src_kbps} kbps; using MP3 CBR ${mp3_bitrate}." >&2
  else
    echo "INFO: Could not detect source bitrate for a:$stream_idx; defaulting to MP3 CBR ${mp3_bitrate}." >&2
  fi

  if (( ch > 2 )); then
    if [[ -n "$PAN_FILTER" ]]; then
      echo "WARNING: Forcing export from 5.1 (${lay:-unknown}) -> stereo MP3 with controlled pan matrix." >&2
      (( INCLUDE_LFE == 1 )) && echo "   LFE included at a low level." >&2
    else
      echo "WARNING: Forcing export from ${ch}-ch (${lay:-unknown}) -> stereo MP3 with FFmpeg default downmix." >&2
    fi
  fi

  echo "Processing: $input  (a:$stream_idx, ${ch}ch${lay:+, $lay})  ->  $out" >&2

  map=(-map "0:a:${stream_idx}")
  audio=(-c:a libmp3lame -b:a "$mp3_bitrate" -joint_stereo 0)

  if [[ -n "$PAN_FILTER" ]]; then
    audio=(-af "$PAN_FILTER" "${audio[@]}")
  fi

  ffmpeg -y -i "$input" "${map[@]}" "${audio[@]}" "$out"

  if [[ $? -eq 0 ]]; then
    echo "Done: $out" >&2
  else
    echo "Failed: $input" >&2
  fi
done
