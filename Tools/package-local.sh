#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/package-local.sh [--configuration debug|release]" >&2
}

configuration="release"
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
  *) echo "Unsupported configuration: $configuration" >&2; exit 2 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
dist_root="${SPEECHLENS_DIST_DIR:-${project_root}/dist/local}"
derived_data="${project_root}/.build/XcodeDerivedData"
xcode_configuration="Debug"
swift_configuration="debug"
if [[ "$configuration" == "release" ]]; then
  xcode_configuration="Release"
  swift_configuration="release"
fi

"${script_dir}/generate-app-icon-assets.sh" --check
"${script_dir}/bootstrap-ffmpeg.sh"
echo "Building the Xcode-owned app (${xcode_configuration})..."
xcodebuild \
  -project "${project_root}/SpeechLens.xcodeproj" \
  -scheme SpeechLens \
  -configuration "$xcode_configuration" \
  -derivedDataPath "$derived_data" \
  -destination "platform=macOS,arch=arm64" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "Building the SwiftPM CLI (${swift_configuration})..."
swift build -c "$swift_configuration" --product speechlens-cli

app_source="${derived_data}/Build/Products/${xcode_configuration}/SpeechLens.app"
cli_source="${project_root}/.build/${swift_configuration}/speechlens-cli"
if [[ ! -x "$cli_source" ]]; then
  cli_source="${project_root}/.build/arm64-apple-macosx/${swift_configuration}/speechlens-cli"
fi
[[ -d "$app_source" ]] || {
  echo "Xcode app product is missing: $app_source" >&2
  exit 1
}
[[ -x "$cli_source" ]] || {
  echo "SwiftPM CLI product is missing: $cli_source" >&2
  exit 1
}

rm -rf "$dist_root"
mkdir -p "$dist_root"
/usr/bin/ditto "$app_source" "${dist_root}/SpeechLens.app"

cli_dir="${dist_root}/speechlens-cli"
ffmpeg_runtime="${SPEECHLENS_FFMPEG_RUNTIME_ROOT:-${project_root}/.build/ffmpeg-runtime}/installed"
mkdir -p "$cli_dir"
/bin/cp "$cli_source" "${cli_dir}/speechlens-cli"
/bin/cp "${ffmpeg_runtime}/ffmpeg" "${cli_dir}/ffmpeg"
/bin/cp "${ffmpeg_runtime}/ffprobe" "${cli_dir}/ffprobe"
/bin/chmod 755 \
  "${cli_dir}/speechlens-cli" \
  "${cli_dir}/ffmpeg" \
  "${cli_dir}/ffprobe"
/bin/cp "${project_root}/LICENSE" "${cli_dir}/LICENSE.txt"
/bin/cp "${ffmpeg_runtime}/SPEECHLENS-FFMPEG.txt" \
  "${cli_dir}/SPEECHLENS-FFMPEG.txt"
"${script_dir}/generate-third-party-licenses.sh" \
  --output "${cli_dir}/THIRD-PARTY-LICENSES.txt"
"${script_dir}/build_mlx_metallib.sh" --output "${cli_dir}/mlx.metallib"

verify_system_dependencies_only() {
  local binary="$1"
  local dependency
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *)
        echo "Unexpected non-system dependency in ${binary}: ${dependency}" >&2
        exit 1
        ;;
    esac
  done < <(otool -L "$binary" | awk 'NR > 1 { print $1 }')
}

app_bundle="${dist_root}/SpeechLens.app"
app_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
  "${app_bundle}/Contents/Info.plist")"
app_icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' \
  "${app_bundle}/Contents/Info.plist")"
if [[ "$app_icon" != "AppIcon" || "$app_icon_name" != "AppIcon" ]]; then
  echo "Packaged app has unexpected icon declarations: file=${app_icon} name=${app_icon_name}" >&2
  exit 1
fi
app_icon_resource="AppIcon.icns"
if [[ -e "${app_bundle}/Contents/Frameworks/Sentry.framework" ]]; then
  echo "Statically linked Sentry framework wrapper must not be packaged" >&2
  exit 1
fi
for binary in \
  "${app_bundle}/Contents/MacOS/SpeechLens" \
  "${app_bundle}/Contents/MacOS/ffmpeg" \
  "${app_bundle}/Contents/MacOS/ffprobe" \
  "${cli_dir}/speechlens-cli" \
  "${cli_dir}/ffmpeg" \
  "${cli_dir}/ffprobe"; do
  [[ -x "$binary" ]] || {
    echo "Packaged executable is missing: $binary" >&2
    exit 1
  }
  verify_system_dependencies_only "$binary"
done

for runtime_item in \
  "${app_bundle}/Contents/Resources/${app_icon_resource}" \
  "${app_bundle}/Contents/Resources/Assets.car" \
  "${app_bundle}/Contents/MacOS/Resources/mlx.metallib" \
  "${app_bundle}/Contents/Resources/PrivacyInfo.xcprivacy" \
  "${app_bundle}/Contents/Resources/LICENSE.txt" \
  "${app_bundle}/Contents/Resources/THIRD-PARTY-LICENSES.txt" \
  "${app_bundle}/Contents/Resources/SPEECHLENS-FFMPEG.txt" \
  "${cli_dir}/mlx.metallib"; do
  [[ -s "$runtime_item" ]] || {
    echo "Packaged runtime item is missing or empty: $runtime_item" >&2
    exit 1
  }
done

packaged_ffmpeg_version="$("${app_bundle}/Contents/MacOS/ffmpeg" -version 2>/dev/null)"
packaged_ffmpeg_version_line="${packaged_ffmpeg_version%%$'\n'*}"
if [[ "$packaged_ffmpeg_version_line" != "ffmpeg version 8.1.2"* ]]; then
  echo "Packaged FFmpeg helper has an unexpected version" >&2
  exit 1
fi
if ! cmp -s "${ffmpeg_runtime}/ffmpeg" \
  "${app_bundle}/Contents/MacOS/ffmpeg"; then
  echo "Packaged FFmpeg helper differs from the verified runtime" >&2
  exit 1
fi
if ! cmp -s "${ffmpeg_runtime}/ffprobe" \
  "${app_bundle}/Contents/MacOS/ffprobe"; then
  echo "Packaged FFprobe helper differs from the verified runtime" >&2
  exit 1
fi

echo "Packaged Xcode app: ${app_bundle}"
echo "Packaged SwiftPM CLI: ${cli_dir}"
