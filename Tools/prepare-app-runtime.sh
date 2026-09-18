#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/prepare-app-runtime.sh --app-bundle <path> [--sign-identity <identity>]" >&2
}

app_bundle=""
sign_identity=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      app_bundle="$2"
      shift 2
      ;;
    --sign-identity)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      sign_identity="$2"
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
[[ -n "$app_bundle" ]] || { usage; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
ffmpeg_runtime="${SPEECHLENS_FFMPEG_RUNTIME_ROOT:-${project_root}/.build/ffmpeg-runtime}/installed"
macos_dir="${app_bundle}/Contents/MacOS"
resources_dir="${app_bundle}/Contents/Resources"
runtime_resources="${macos_dir}/Resources"
sentry_framework="${app_bundle}/Contents/Frameworks/Sentry.framework"

# Sentry's SPM product is statically linked into SpeechLens, but Xcode also
# copies the binary-target framework wrapper for its resources. It has no load
# command and must not ship as unused executable code. SpeechLens declares the
# audited required-reason APIs in its own privacy manifest.
if [[ -d "$sentry_framework" ]]; then
  if otool -L "${macos_dir}/SpeechLens" | rg -Fq "Sentry.framework"; then
    echo "Sentry unexpectedly requires a dynamic runtime framework" >&2
    exit 1
  fi
  rm -rf "$sentry_framework"
fi

"${script_dir}/bootstrap-ffmpeg.sh"
mkdir -p "$macos_dir" "$resources_dir" "$runtime_resources"
for helper in ffmpeg ffprobe; do
  /bin/cp "${ffmpeg_runtime}/${helper}" "${macos_dir}/${helper}"
  /bin/chmod 755 "${macos_dir}/${helper}"
done
"${script_dir}/build_mlx_metallib.sh" \
  --output "${runtime_resources}/mlx.metallib"
/bin/cp "${project_root}/LICENSE" "${resources_dir}/LICENSE.txt"
/bin/cp "${ffmpeg_runtime}/SPEECHLENS-FFMPEG.txt" \
  "${resources_dir}/SPEECHLENS-FFMPEG.txt"
"${script_dir}/generate-third-party-licenses.sh" \
  --output "${resources_dir}/THIRD-PARTY-LICENSES.txt"

if [[ -n "$sign_identity" ]]; then
  for nested_code in \
    "${macos_dir}/ffmpeg" \
    "${macos_dir}/ffprobe" \
    "${runtime_resources}/mlx.metallib"; do
    if [[ "$sign_identity" == "-" ]]; then
      /usr/bin/codesign --force --sign - "$nested_code"
    else
      /usr/bin/codesign --force --options runtime --timestamp \
        --sign "$sign_identity" "$nested_code"
    fi
    /usr/bin/codesign --verify --strict --verbose=2 "$nested_code"
  done
fi

for required in \
  "${macos_dir}/ffmpeg" \
  "${macos_dir}/ffprobe" \
  "${runtime_resources}/mlx.metallib" \
  "${resources_dir}/LICENSE.txt" \
  "${resources_dir}/THIRD-PARTY-LICENSES.txt" \
  "${resources_dir}/SPEECHLENS-FFMPEG.txt"; do
  [[ -s "$required" ]] || {
    echo "Required app runtime item is missing or empty: $required" >&2
    exit 1
  }
done
