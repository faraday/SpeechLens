#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/create-dmg.sh --app /path/to/SpeechLens.app --output /path/to/SpeechLens.dmg [--volume-name SpeechLens]" >&2
}

app_bundle=""
output_dmg=""
volume_name="SpeechLens"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      app_bundle="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output_dmg="$2"
      shift 2
      ;;
    --volume-name)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      volume_name="$2"
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

[[ -n "$app_bundle" && -n "$output_dmg" ]] || { usage; exit 2; }
[[ -d "$app_bundle" ]] || { echo "App bundle not found: $app_bundle" >&2; exit 1; }

output_dir="$(cd "$(dirname "$output_dmg")" && pwd)"
output_name="$(basename "$output_dmg")"
final_dmg="${output_dir}/${output_name}"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/speechlens-dmg.XXXXXX")"

cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

cp -R "$app_bundle" "$staging_dir/"
ln -s /Applications "$staging_dir/Applications"

rm -f "$final_dmg"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -quiet \
  "$final_dmg"
echo "Created DMG: $final_dmg"
