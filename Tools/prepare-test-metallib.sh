#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/prepare-test-metallib.sh [--configuration debug|release]" >&2
}

configuration="debug"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      configuration="$2"
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

case "$configuration" in
  debug|release) ;;
  *)
    echo "Unsupported configuration: $configuration" >&2
    usage
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"

swift_args=(--build-tests -Xswiftc -enable-testing)
if [[ "$configuration" == "release" ]]; then
  swift_args=(-c release --build-tests -Xswiftc -enable-testing)
fi

echo "Building SpeechLens tests ($configuration)..."
(cd "$project_root" && swift build "${swift_args[@]}")

bundle_macos=""
while IFS= read -r candidate; do
  bundle_macos="$candidate"
done < <(
  find "${project_root}/.build" \
    -type d \
    -path "*/${configuration}/SpeechLensPackageTests.xctest/Contents/MacOS" \
    | sort
)

if [[ -z "$bundle_macos" ]]; then
  echo "Unable to find SpeechLensPackageTests.xctest for configuration: $configuration" >&2
  exit 1
fi

"${script_dir}/build_mlx_metallib.sh" --output "${bundle_macos}/mlx.metallib"
echo "Prepared test MLX metallib: ${bundle_macos}/mlx.metallib"
