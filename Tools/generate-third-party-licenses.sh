#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/generate-third-party-licenses.sh --output <path>" >&2
}

output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done
[[ -n "$output" ]] || { usage; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
ffmpeg_runtime="${SPEECHLENS_FFMPEG_RUNTIME_ROOT:-${project_root}/.build/ffmpeg-runtime}/installed"
mlx_checkout="${project_root}/.build/checkouts/mlx-swift"

mkdir -p "$(dirname "$output")"
printf '%s\n' \
  "SpeechLens Third-Party Licenses" \
  "" \
  "This distribution contains the third-party components and license texts below." \
  > "$output"

append_license() {
  local component="$1"
  local license_path="$2"
  [[ -s "$license_path" ]] || {
    echo "Required third-party license is missing or empty: $license_path" >&2
    exit 1
  }
  {
    printf '\n================================================================================\n'
    printf '%s\n' "$component"
    printf 'Source license: %s\n' "${license_path#${project_root}/}"
    printf '================================================================================\n\n'
    /bin/cat "$license_path"
    printf '\n'
  } >> "$output"
}

append_license "MLX Swift" "${mlx_checkout}/LICENSE"
append_license "Apple MLX" "${mlx_checkout}/Source/Cmlx/mlx/LICENSE"
append_license "MLX C" "${mlx_checkout}/Source/Cmlx/mlx-c/LICENSE"
append_license "fmt" "${mlx_checkout}/Source/Cmlx/fmt/LICENSE"
append_license "JSON for Modern C++" "${mlx_checkout}/Source/Cmlx/json/LICENSE.MIT"
append_license "metal-cpp" "${mlx_checkout}/Source/Cmlx/metal-cpp/LICENSE.txt"
append_license "Swift Numerics" "${project_root}/.build/checkouts/swift-numerics/LICENSE.txt"
append_license "Swift Argument Parser" "${project_root}/.build/checkouts/swift-argument-parser/LICENSE.txt"
append_license "Sentry Cocoa 9.24.0" "${project_root}/ThirdPartyLicenses/Sentry-Cocoa-LICENSE.md"
append_license "FFmpeg 8.1.2" "${ffmpeg_runtime}/FFMPEG-LGPL-2.1.txt"
append_license "LAME 3.100" "${ffmpeg_runtime}/LAME-LGPL-2.0.txt"
