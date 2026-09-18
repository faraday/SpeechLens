#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/build_mlx_metallib.sh --output <path/to/mlx.metallib>" >&2
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

compatible_metallib() {
  local path="$1"
  [[ -s "$path" ]] && /usr/bin/grep -a -q "layer_normfloat32" "$path"
}

install_metallib() {
  local source="$1"
  local destination="$2"
  local destination_dir
  destination_dir="$(dirname "$destination")"
  mkdir -p "$destination_dir"
  cp "$source" "$destination"
  if ! compatible_metallib "$destination"; then
    echo "Installed mlx.metallib is incompatible: $destination" >&2
    exit 1
  fi
  echo "Installed MLX metallib: $destination"
}

if [[ -n "${MLX_METALLIB_PATH:-}" ]]; then
  if ! compatible_metallib "$MLX_METALLIB_PATH"; then
    echo "MLX_METALLIB_PATH does not point to a compatible metallib: $MLX_METALLIB_PATH" >&2
    exit 1
  fi
  install_metallib "$MLX_METALLIB_PATH" "$output"
  exit 0
fi

metal_root="${project_root}/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [[ ! -d "$metal_root" ]]; then
  echo "MLX generated Metal sources are missing. Resolving Swift package dependencies..." >&2
  (cd "$project_root" && swift package resolve)
fi

if [[ ! -d "$metal_root" ]]; then
  echo "Unable to locate MLX generated Metal sources at: $metal_root" >&2
  echo "Run swift package resolve/build first, or set MLX_METALLIB_PATH for build-time override." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to build mlx.metallib. Install and select Xcode 26 or newer." >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/speechlens-mlx-metallib.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

include_root="$(dirname "$metal_root")"
air_files=()

while IFS= read -r src; do
  rel="${src#${metal_root}/}"
  air="${tmp_dir}/${rel//\//_}.air"
  xcrun -sdk macosx metal \
    -x metal \
    -c "$src" \
    -I "$metal_root" \
    -I "$include_root" \
    -o "$air"
  air_files+=("$air")
done < <(find "$metal_root" -type f -name '*.metal' | sort)

if [[ "${#air_files[@]}" -eq 0 ]]; then
  echo "No .metal files found in $metal_root" >&2
  exit 1
fi

built_metallib="${tmp_dir}/mlx.metallib"
xcrun -sdk macosx metallib "${air_files[@]}" -o "$built_metallib"

if ! compatible_metallib "$built_metallib"; then
  echo "Built mlx.metallib is incompatible: $built_metallib" >&2
  exit 1
fi

install_metallib "$built_metallib" "$output"
