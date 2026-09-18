#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/generate-app-icon-assets.sh --write|--check" >&2
}

mode="${1:-}"
case "$mode" in
  --write|--check) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
source_icon="${project_root}/Assets/AppIcon/SpeechLens.png"
icon_set="${project_root}/Sources/App/Assets.xcassets/AppIcon.appiconset"

[[ -s "$source_icon" ]] || {
  echo "Canonical app icon is missing or empty: ${source_icon}" >&2
  exit 1
}
[[ -d "$icon_set" ]] || {
  echo "App icon set is missing: ${icon_set}" >&2
  exit 1
}

source_width="$(/usr/bin/sips -g pixelWidth "$source_icon" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
source_height="$(/usr/bin/sips -g pixelHeight "$source_icon" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
if [[ "$source_width" != "2048" || "$source_height" != "2048" ]]; then
  echo "Canonical app icon must be 2048x2048; found ${source_width}x${source_height}" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/speechlens-app-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

cat > "${work_dir}/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

icon_specs=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

expected_files=(Contents.json)
for spec in "${icon_specs[@]}"; do
  filename="${spec%%:*}"
  pixels="${spec##*:}"
  expected_files+=("$filename")
  /usr/bin/sips -z "$pixels" "$pixels" "$source_icon" \
    --out "${work_dir}/${filename}" >/dev/null
done

if [[ "$mode" == "--write" ]]; then
  for filename in "${expected_files[@]}"; do
    /bin/cp "${work_dir}/${filename}" "${icon_set}/${filename}"
  done
  echo "Generated app icon assets from ${source_icon}"
  exit 0
fi

failed=0
for filename in "${expected_files[@]}"; do
  if [[ ! -f "${icon_set}/${filename}" ]]; then
    echo "App icon asset is missing: ${icon_set}/${filename}" >&2
    failed=1
  elif ! cmp -s "${work_dir}/${filename}" "${icon_set}/${filename}"; then
    echo "App icon asset is stale: ${icon_set}/${filename}" >&2
    failed=1
  fi
done

for path in "${icon_set}"/*; do
  filename="$(basename "$path")"
  known=0
  for expected in "${expected_files[@]}"; do
    if [[ "$filename" == "$expected" ]]; then
      known=1
      break
    fi
  done
  if [[ "$known" -eq 0 ]]; then
    echo "Unexpected app icon asset: ${path}" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Run Tools/generate-app-icon-assets.sh --write to refresh the catalog." >&2
  exit 1
fi

echo "App icon assets match ${source_icon}"
