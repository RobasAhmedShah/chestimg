#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Credentials can be supplied through environment variables or entered securely
# when the script is run interactively.
PHYSIONET_USER="${PHYSIONET_USER:-}"
PHYSIONET_PASS="${PHYSIONET_PASS:-}"
LIST_FILE="${LIST_FILE:-$SCRIPT_DIR/IMAGE_FILENAMES}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/physionet_parallel}"
BASE_URL="${BASE_URL:-https://physionet.org/files/mimic-cxr-jpg/2.1.0}"
LIMIT="${LIMIT:-100}"
START_INDEX="${START_INDEX:-1}"
JOBS="${JOBS:-5}"
WGET_TIMEOUT="${WGET_TIMEOUT:-90}"
WGET_TRIES="${WGET_TRIES:-2}"
WGET_HARD_TIMEOUT="${WGET_HARD_TIMEOUT:-240}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}"
ESTIMATED_IMAGE_MIB="${ESTIMATED_IMAGE_MIB:-1.5}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
REPLACE="${REPLACE:-0}"

usage() {
  printf '%s\n' \
    "Usage: $0 [options]" \
    "" \
    "Options:" \
    "  -l, --list FILE       Filename list to read (default: $LIST_FILE)" \
    "  -s, --start NUMBER    1-based line number in IMAGE_FILENAMES to start from (default: $START_INDEX)" \
    "  -n, --images NUMBER   Number of images to process (default: $LIMIT)" \
    "  -j, --jobs NUMBER     Parallel downloads (default: $JOBS)" \
    "  -o, --output DIR      Download directory (default: $OUT_DIR)" \
    "  -r, --replace         Fully re-download and safely replace existing files" \
    "  -h, --help            Show this help" \
    "" \
    "Examples:" \
    "  $0 --replace --images 1000 --jobs 5" \
    "  $0 --start 11 --images 10 --jobs 5" \
    "  $0 -n 5000 -j 8 -o /path/to/downloads"
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "Option $1 requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--list)
      require_value "$@"
      LIST_FILE="$2"
      shift 2
      ;;
    --list=*)
      LIST_FILE="${1#*=}"
      shift
      ;;
    -s|--start)
      require_value "$@"
      START_INDEX="$2"
      shift 2
      ;;
    --start=*)
      START_INDEX="${1#*=}"
      shift
      ;;
    -n|--images)
      require_value "$@"
      LIMIT="$2"
      shift 2
      ;;
    --images=*)
      LIMIT="${1#*=}"
      shift
      ;;
    -j|--jobs)
      require_value "$@"
      JOBS="$2"
      shift 2
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      shift
      ;;
    -o|--output)
      require_value "$@"
      OUT_DIR="$2"
      shift 2
      ;;
    --output=*)
      OUT_DIR="${1#*=}"
      shift
      ;;
    -r|--replace)
      REPLACE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help for usage)"
      ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*) die "--images must be a positive integer." ;;
esac
case "$START_INDEX" in
  ''|*[!0-9]*) die "--start must be a positive integer." ;;
esac
case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer." ;;
esac
[[ "$LIMIT" -gt 0 ]] || die "--images must be greater than zero."
[[ "$START_INDEX" -gt 0 ]] || die "--start must be greater than zero."
[[ "$JOBS" -gt 0 ]] || die "--jobs must be greater than zero."
[[ "$REPLACE" == "0" || "$REPLACE" == "1" ]] || die "REPLACE must be either 0 or 1."
[[ -f "$LIST_FILE" ]] || die "List file not found: $LIST_FILE"
command -v wget >/dev/null 2>&1 || die "wget is required but was not found."

if [[ -z "$PHYSIONET_USER" ]]; then
  [[ -t 0 ]] || die "Set PHYSIONET_USER for non-interactive use."
  read -r -p "PhysioNet username: " PHYSIONET_USER
fi
if [[ -z "$PHYSIONET_PASS" ]]; then
  [[ -t 0 ]] || die "Set PHYSIONET_PASS for non-interactive use."
  read -r -s -p "PhysioNet password: " PHYSIONET_PASS
  echo
fi
[[ -n "$PHYSIONET_USER" && -n "$PHYSIONET_PASS" ]] || die "PhysioNet credentials are empty."

mkdir -p "$OUT_DIR" || die "Could not create output directory: $OUT_DIR"

urls_file="$(mktemp)" || die "Could not create a temporary URL file."
log_dir="$(mktemp -d)" || die "Could not create a temporary log directory."
wget_config="$(mktemp)" || die "Could not create a temporary wget config."
monitor_pid=""

cleanup() {
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" 2>/dev/null || true
  fi
  rm -f "$urls_file" "$wget_config"
  rm -rf "$log_dir"
}
trap cleanup EXIT
trap 'echo "Interrupted; stopping without a success summary." >&2; exit 130' INT
trap 'echo "Terminated; stopping without a success summary." >&2; exit 143' TERM

# Keep the password out of the wget process arguments and restrict the temp file.
chmod 600 "$wget_config"
printf 'user = %s\npassword = %s\n' "$PHYSIONET_USER" "$PHYSIONET_PASS" > "$wget_config"
export WGETRC="$wget_config"

# Select the first NUMBER non-empty entries and remove Windows carriage returns.
awk -v base="$BASE_URL" -v limit="$LIMIT" -v start="$START_INDEX" '
  { sub(/\r$/, "") }
  NF {
    usable++;
    if (usable < start) next;
    print base "/" $0;
    count++;
    if (count >= limit) exit
  }
' "$LIST_FILE" > "$urls_file"

requested="$(wc -l < "$urls_file" | tr -d ' ')"
[[ "$requested" -gt 0 ]] || die "The image list contains no usable entries."

if [[ "$requested" -lt "$LIMIT" ]]; then
  echo "NOTICE: requested $LIMIT images, but the list contains only $requested usable entries."
fi

echo "Starting $requested downloads with $JOBS parallel jobs."
echo "Start index: $START_INDEX"
echo "Output: $OUT_DIR"
if [[ "$REPLACE" == "1" ]]; then
  echo "Mode: replace (every selected image will be fully downloaded again)"
else
  echo "Mode: resume (existing images may finish almost instantly)"
fi
start_epoch="$(date +%s)"

current_transferred_bytes() {
  find "$log_dir" -type f -name '*.track' -exec bash -c '
    for tracking_file do
      item_base="${tracking_file%.track}"
      if [[ -f "$item_base.bytes" ]]; then
        cat "$item_base.bytes"
        continue
      fi

      tracked_path="$(sed -n "1p" "$tracking_file")"
      tracked_before="$(sed -n "2p" "$tracking_file")"
      tracked_before="${tracked_before:-0}"
      if [[ -f "$tracked_path" ]]; then
        current_size="$(wc -c < "$tracked_path" | tr -d " ")"
        if [[ "$current_size" -gt "$tracked_before" ]]; then
          echo "$((current_size - tracked_before))"
        else
          echo 0
        fi
      else
        echo 0
      fi
    done
  ' _ {} + 2>/dev/null | awk '{sum += $1} END {printf "%.0f", sum}'
}

format_duration() {
  total_seconds="${1:-0}"
  if [[ "$total_seconds" == "--" ]]; then
    printf '%s' "--:--"
    return
  fi
  hours="$((total_seconds / 3600))"
  minutes="$(((total_seconds % 3600) / 60))"
  seconds="$((total_seconds % 60))"
  if [[ "$hours" -gt 0 ]]; then
    printf '%d:%02d:%02d' "$hours" "$minutes" "$seconds"
  else
    printf '%02d:%02d' "$minutes" "$seconds"
  fi
}

progress_monitor() {
  while true; do
    now_epoch="$(date +%s)"
    elapsed="$((now_epoch - start_epoch))"
    completed_count="$(find "$log_dir" -type f -name '*.rc' 2>/dev/null | wc -l | tr -d ' ')"
    success_count="$(find "$log_dir" -type f -name '*.rc' -exec awk '$1 == 0 {count++} END {print count+0}' {} + 2>/dev/null)"
    failure_count="$(find "$log_dir" -type f -name '*.rc' -exec awk '$1 != 0 {count++} END {print count+0}' {} + 2>/dev/null)"
    success_count="${success_count:-0}"
    failure_count="${failure_count:-0}"
    transferred_bytes="$(current_transferred_bytes)"
    transferred_bytes="${transferred_bytes:-0}"
    speed_elapsed="$elapsed"
    [[ "$speed_elapsed" -le 0 ]] && speed_elapsed=1
    progress_stats="$(awk \
      -v bytes="$transferred_bytes" \
      -v seconds="$speed_elapsed" \
      -v completed="$completed_count" \
      -v success="$success_count" \
      -v requested="$requested" \
      -v estimated_image_mib="$ESTIMATED_IMAGE_MIB" '
      BEGIN {
        speed_bps = bytes / seconds
        speed_mib = speed_bps / 1048576
        transferred_mib = bytes / 1048576
        percent = requested > 0 ? completed / requested * 100 : 0
        if (speed_bps > 0) {
          # Use a baseline immediately; completed downloads refine it.
          avg_bytes = estimated_image_mib * 1048576
          if (success > 0) {
            observed_avg = bytes / success
            avg_bytes = (avg_bytes + observed_avg) / 2
          }
          estimated_total = avg_bytes * requested
          eta = int((estimated_total - bytes) / speed_bps)
          if (eta < 0) eta = 0
        } else {
          eta = -1
        }
        printf "%.0f %.2f %.3f %d", percent, transferred_mib, speed_mib, eta
      }')"
    read -r percent transferred_mib speed_mib eta_seconds <<< "$progress_stats"
    bar_width=30
    filled="$((completed_count * bar_width / requested))"
    empty="$((bar_width - filled))"
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
    if [[ "$eta_seconds" -lt 0 ]]; then
      eta_text="--:--"
    else
      eta_text="$(format_duration "$eta_seconds")"
    fi
    elapsed_text="$(format_duration "$elapsed")"
    echo "[$bar] ${percent}% | completed $completed_count/$requested | ok $success_count | failed $failure_count | downloaded ${transferred_mib} MiB | speed ${speed_mib} MiB/s | elapsed $elapsed_text | ETA $eta_text"
    sleep "$PROGRESS_INTERVAL"
  done
}

download_one() {
  url="$1"
  index="$2"
  worker_log_dir="$3"
  log_file="$worker_log_dir/$index.log"
  status_file="$worker_log_dir/$index.rc"
  bytes_file="$worker_log_dir/$index.bytes"
  relative_path="${url#*://}"
  destination="$OUT_DIR/$relative_path"
  before_size=0
  if [[ -f "$destination" ]]; then
    before_size="$(wc -c < "$destination" | tr -d ' ')"
  fi

  if [[ "$REPLACE" == "1" ]]; then
    replacement_file="${destination}.replace.part"
    mkdir -p "$(dirname "$destination")"
    printf '%s\n0\n' "$replacement_file" > "$worker_log_dir/$index.track"
    wget_args=(
      -nv
      --no-cache
      --timeout="$WGET_TIMEOUT"
      --tries="$WGET_TRIES"
      -O "$replacement_file"
      "$url"
    )
  else
    printf '%s\n%s\n' "$destination" "$before_size" > "$worker_log_dir/$index.track"
    wget_args=(
      -nv
      -N
      -c
      -np
      -x
      --timeout="$WGET_TIMEOUT"
      --tries="$WGET_TRIES"
      --directory-prefix="$OUT_DIR"
      "$url"
    )
  fi

  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$WGET_HARD_TIMEOUT" wget "${wget_args[@]}" >"$log_file" 2>&1
  else
    wget "${wget_args[@]}" >"$log_file" 2>&1
  fi
  rc="$?"

  transferred_bytes=0
  if [[ "$REPLACE" == "1" && "$rc" == "0" && -f "$replacement_file" ]]; then
    transferred_bytes="$(wc -c < "$replacement_file" | tr -d ' ')"
    echo "$transferred_bytes" > "$bytes_file"
    mv -f "$replacement_file" "$destination"
    rc="$?"
    if [[ "$rc" != "0" ]]; then
      transferred_bytes=0
    fi
  elif [[ "$REPLACE" == "1" ]]; then
    rm -f "$replacement_file"
  elif [[ "$rc" == "0" && -f "$destination" ]]; then
    after_size="$(wc -c < "$destination" | tr -d ' ')"
    if [[ "$after_size" -gt "$before_size" ]]; then
      transferred_bytes="$((after_size - before_size))"
    fi
  fi

  echo "$transferred_bytes" > "$bytes_file"
  echo "$rc" > "$status_file"
  return 0
}

export -f download_one
export OUT_DIR WGET_TIMEOUT WGET_TRIES WGET_HARD_TIMEOUT TIMEOUT_BIN WGETRC REPLACE

progress_monitor &
monitor_pid="$!"

paste <(seq 1 "$requested") "$urls_file" |
  xargs -P "$JOBS" -n 2 bash -c 'download_one "$3" "$2" "$1"' _ "$log_dir"

kill "$monitor_pid" 2>/dev/null || true
monitor_pid=""

end_epoch="$(date +%s)"
elapsed="$((end_epoch - start_epoch))"
[[ "$elapsed" -le 0 ]] && elapsed=1

success_count="$(find "$log_dir" -type f -name '*.rc' -exec awk '$1 == 0 {count++} END {print count+0}' {} +)"
failure_count="$(find "$log_dir" -type f -name '*.rc' -exec awk '$1 != 0 {count++} END {print count+0}' {} +)"
success_count="${success_count:-0}"
failure_count="${failure_count:-0}"
transferred_bytes="$(find "$log_dir" -type f -name '*.bytes' -exec awk '{sum += $1} END {printf "%.0f", sum}' {} +)"
transferred_bytes="${transferred_bytes:-0}"
speed_stats="$(awk -v bytes="$transferred_bytes" -v seconds="$elapsed" 'BEGIN {
  printf "transferred_bytes=%.0f\ntransferred_mib=%.2f\nspeed_mib_s=%.3f", bytes, bytes / 1048576, bytes / seconds / 1048576
}')"

echo "SUMMARY"
echo "requested=$requested"
echo "jobs=$JOBS"
echo "replace=$REPLACE"
echo "elapsed_seconds=$elapsed"
echo "success_count=$success_count"
echo "failure_count=$failure_count"
echo "$speed_stats"

if [[ "$failure_count" -gt 0 ]]; then
  echo "FAILURE_SAMPLE"
  find "$log_dir" -type f -name '*.rc' | sort | while IFS= read -r status_file; do
    [[ "$(cat "$status_file")" == "0" ]] && continue
    log_file="${status_file%.rc}.log"
    echo "--- item $(basename "${status_file%.rc}") rc=$(cat "$status_file")"
    tail -n 5 "$log_file"
  done | head -n 80
  exit 1
fi

echo "All requested downloads completed successfully."
