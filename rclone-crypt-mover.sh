#!/usr/bin/env bash
set -euo pipefail

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd rclone
need_cmd fzf
need_cmd awk
need_cmd sed

# ---------------- macOS sleep prevention ----------------
CAFFEINATE_PID=""

start_caffeinate() {
  # Only on macOS, only if caffeinate exists
  if [[ "$(uname -s)" == "Darwin" ]] && command -v caffeinate >/dev/null 2>&1; then
    echo "Preventing system sleep (caffeinate)"
    caffeinate -i &
    CAFFEINATE_PID=$!
  fi
}

stop_caffeinate() {
  if [[ -n "$CAFFEINATE_PID" ]]; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
  fi
}

trap stop_caffeinate EXIT INT TERM
# -------------------------------------------------------

COMMIT=0
FROM_LOCAL=""

# ---------------- argument parsing ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)
      COMMIT=1
      shift
      ;;
    --from-local)
      shift
      [[ -z "${1:-}" ]] && { echo "Error: --from-local requires a path" >&2; exit 2; }
      FROM_LOCAL="$1"
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  rclone-crypt-mover.sh
  rclone-crypt-mover.sh --commit
  rclone-crypt-mover.sh --from-local <path>
  rclone-crypt-mover.sh --from-local <path> --commit

Modes:
  Default:
    Interactive move between plaintext and crypt remotes (encrypt/decrypt).
    Dry-run by default.

  --from-local <path>:
    Copy a local file or directory to a selected remote destination.
    Uses copy (never move). Dry-run by default.

Options:
  --commit   Perform real operations (otherwise dry-run)
  --help     Show this help

Notes:
  - On macOS, the script will run `caffeinate -i` after confirmation to prevent sleep.
EOF
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# ---------------- remote roots ----------------
MOV_AVAIL='db:ADCC Folders/ADCC Proxies/Movies/available'
MOV_ACTV='db:ADCC Folders/ADCC Proxies/Movies/Active'
TV_AVAIL='db:ADCC Folders/ADCC Proxies/Shows/available'
TV_ACTV='db:ADCC Folders/ADCC Proxies/Shows/Active'

CRYPT_MOV='dbcrypt-movies:'
CRYPT_TV='dbcrypt-tv:'

pick() {
  local prompt="$1"
  local choices="$2"
  printf "%s\n" "$choices" | sed '/^[[:space:]]*$/d' | fzf --prompt="$prompt" --border
}

join_path() {
  local root="$1"
  local rel="$2"
  root="${root%/}"
  if [[ "$root" == *: ]]; then
    printf "%s%s" "$root" "$rel"
  else
    printf "%s/%s" "$root" "$rel"
  fi
}

# ==================================================
# =============== LOCAL UPLOAD MODE ================
# ==================================================
if [[ -n "$FROM_LOCAL" ]]; then
  [[ ! -e "$FROM_LOCAL" ]] && { echo "Local path does not exist: $FROM_LOCAL" >&2; exit 1; }

  BASENAME="$(basename "$FROM_LOCAL")"

  DEST_LINE="$(pick "Pick upload destination > " "
Movies → available (plain) | $MOV_AVAIL
Movies → Active (plain)    | $MOV_ACTV
Shows  → available (plain) | $TV_AVAIL
Shows  → Active (plain)    | $TV_ACTV
Movies → crypt             | $CRYPT_MOV
Shows  → crypt             | $CRYPT_TV
")" || exit 0

  DEST_ROOT="$(echo "$DEST_LINE" | awk -F ' *\\| *' '{print $2}')"
  DEST_PATH="$(join_path "$DEST_ROOT" "$BASENAME")"

  echo
  echo "Upload source: $FROM_LOCAL"
  echo "Destination:   $DEST_PATH"
  echo

  if [[ $COMMIT -eq 1 ]]; then
    echo "MODE: REAL COPY"
  else
    echo "MODE: DRY RUN"
  fi
  echo

  read -r -p "Proceed? (yes/no): " confirm
  case "$confirm" in yes|y|Y) ;; *) echo "Cancelled."; exit 0 ;; esac

  # Start sleep prevention only after user confirms
  start_caffeinate

  if [[ -d "$FROM_LOCAL" ]]; then
    CMD=(rclone copy "$FROM_LOCAL" "$DEST_PATH" -P -v)
  else
    CMD=(rclone copyto "$FROM_LOCAL" "$DEST_PATH" -P -v)
  fi

  [[ $COMMIT -eq 0 ]] && CMD+=(--dry-run)

  echo
  echo "Running:"
  printf "  %q" "${CMD[@]}"
  echo
  echo

  "${CMD[@]}"
  echo "Done."
  exit 0
fi

# ==================================================
# ========== ENCRYPT / DECRYPT MOVE MODE ===========
# ==================================================

direction="$(pick "Pick direction > " "
Encrypt (plain → crypt)
Decrypt (crypt → plain)
")" || exit 0

if [[ "$direction" == Encrypt* ]]; then
  ROUTES="
Movies (available → crypt) | $MOV_AVAIL | $CRYPT_MOV
Movies (Active → crypt)    | $MOV_ACTV  | $CRYPT_MOV
Shows (available → crypt)  | $TV_AVAIL  | $CRYPT_TV
Shows (Active → crypt)     | $TV_ACTV   | $CRYPT_TV
"
else
  ROUTES="
Movies (crypt → available) | $CRYPT_MOV | $MOV_AVAIL
Movies (crypt → Active)    | $CRYPT_MOV | $MOV_ACTV
Shows (crypt → available)  | $CRYPT_TV  | $TV_AVAIL
Shows (crypt → Active)     | $CRYPT_TV  | $TV_ACTV
"
fi

route_line="$(pick "Pick a route > " "$ROUTES")" || exit 0

label="$(echo "$route_line" | awk -F ' *\\| *' '{print $1}')"
src_root="$(echo "$route_line" | awk -F ' *\\| *' '{print $2}')"
dst_root="$(echo "$route_line" | awk -F ' *\\| *' '{print $3}')"

echo
echo "Route:       $label"
echo "Source:      $src_root"
echo "Destination: $dst_root"
echo

selections="$(
  rclone lsf -R --fast-list "$src_root" \
    | fzf -m --prompt="Select files/dirs to MOVE > " --border --height=80%
)"

[[ -z "$selections" ]] && { echo "No files selected."; exit 0; }

echo
echo "You selected:"
echo "$selections" | sed 's/^/  - /'
echo

[[ $COMMIT -eq 1 ]] && echo "MODE: REAL MOVE" || echo "MODE: DRY RUN"
echo

read -r -p "Proceed? (yes/no): " confirm
case "$confirm" in yes|y|Y) ;; *) echo "Cancelled."; exit 0 ;; esac

# Start sleep prevention only after user confirms
start_caffeinate

echo
echo "$selections" | while IFS= read -r rel; do
  rel="${rel%$'\r'}"
  rel_no_slash="${rel%/}"

  src_item="$(join_path "$src_root" "$rel_no_slash")"
  dst_item="$(join_path "$dst_root" "$rel_no_slash")"

  # --- destination-exists protection (commit mode only) ---
  if [[ $COMMIT -eq 1 ]]; then
    is_dir=0
    [[ "$rel" == */ ]] && is_dir=1

    leaf="${rel_no_slash##*/}"
    parent_rel=""
    if [[ "$rel_no_slash" == */* ]]; then
      parent_rel="${rel_no_slash%/*}"
    fi

    dst_parent="$dst_root"
    if [[ -n "$parent_rel" ]]; then
      dst_parent="$(join_path "$dst_root" "$parent_rel")"
    fi

    exists=0
    if [[ $is_dir -eq 1 ]]; then
      rclone lsf "$dst_parent" 2>/dev/null | grep -Fxq "${leaf}/" && exists=1
    else
      rclone lsf "$dst_parent" 2>/dev/null | grep -Fxq "${leaf}" && exists=1
    fi

    if [[ $exists -eq 1 ]]; then
      echo "WARNING: destination already contains: $dst_item"
      read -r -p "Skip this item? (yes/no): " ans
      case "$ans" in
        yes|y|Y) echo "Skipping."; echo; continue ;;
      esac
    fi
  fi
  # --- end destination-exists protection ---

  echo "Moving:"
  echo "  FROM: $src_item"
  echo "  TO:   $dst_item"
  echo

  if [[ $COMMIT -eq 1 ]]; then
    rclone moveto "$src_item" "$dst_item" -P -v
  else
    rclone moveto "$src_item" "$dst_item" -P -v --dry-run
  fi
  echo
done

echo "Done."
