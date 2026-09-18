#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/benchmark-avi.sh --input file.avi --output file.avi --weights model.safetensors" >&2
}

input=""
output=""
weights=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) input="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --weights) weights="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
if [[ -z "$input" || -z "$output" || -z "$weights" ]]; then
  usage
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
runtime="${SPEECHLENS_FFMPEG_RUNTIME_ROOT:-${project_root}/.build/ffmpeg-runtime}/installed"
benchmark_root="$(mktemp -d "${TMPDIR:-/tmp}/speechlens-avi-benchmark.XXXXXX")"
cleanup() {
  if [[ -d "$benchmark_root" ]]; then
    find "$benchmark_root" -depth -delete
  fi
}
trap cleanup EXIT

"${script_dir}/bootstrap-ffmpeg.sh"
(cd "$project_root" && swift build -c release --product speechlens-cli)
cli="${project_root}/.build/release/speechlens-cli"
if [[ ! -x "$cli" ]]; then
  cli="${project_root}/.build/arm64-apple-macosx/release/speechlens-cli"
fi

ffmpeg_log="${benchmark_root}/ffmpeg-invocations.log"
ffprobe_log="${benchmark_root}/ffprobe-invocations.log"
ffmpeg_wrapper="${benchmark_root}/ffmpeg"
ffprobe_wrapper="${benchmark_root}/ffprobe"
cat > "$ffmpeg_wrapper" <<WRAPPER
#!/bin/sh
printf 'invoke\n' >> "$ffmpeg_log"
exec "$runtime/ffmpeg" "\$@"
WRAPPER
cat > "$ffprobe_wrapper" <<WRAPPER
#!/bin/sh
printf 'invoke\n' >> "$ffprobe_log"
exec "$runtime/ffprobe" "\$@"
WRAPPER
chmod 755 "$ffmpeg_wrapper" "$ffprobe_wrapper"

work_tmp="${benchmark_root}/tmp"
mkdir -p "$work_tmp"
peak_file="${benchmark_root}/peak-kib"
stop_file="${benchmark_root}/monitor-stop"
(
  peak=0
  while [[ ! -e "$stop_file" ]]; do
    current="$(du -sk "$work_tmp" | awk '{print $1}')"
    if (( current > peak )); then peak="$current"; fi
    printf '%s\n' "$peak" > "$peak_file"
    sleep 0.1
  done
) &
monitor_pid=$!

run_log="${benchmark_root}/run.log"
status=0
TMPDIR="$work_tmp" \
SPEECHLENS_FFMPEG="$ffmpeg_wrapper" \
SPEECHLENS_FFPROBE="$ffprobe_wrapper" \
  /usr/bin/time -l "$cli" \
    --weights "$weights" \
    --input "$input" \
    --output "$output" \
    2> "$run_log" || status=$?
touch "$stop_file"
wait "$monitor_pid"

echo "AVI benchmark"
echo "Input: $input"
grep -E '^(PhaseTiming|TotalTiming)' "$run_log" || true
grep -E 'maximum resident set size' "$run_log" || true
echo "FFmpeg invocations: $(wc -l < "$ffmpeg_log" | tr -d ' ')"
echo "FFprobe invocations: $(wc -l < "$ffprobe_log" | tr -d ' ')"
echo "Peak helper temporary storage: $(cat "$peak_file") KiB"
if (( status != 0 )); then
  tail -n 40 "$run_log" >&2
  exit "$status"
fi
