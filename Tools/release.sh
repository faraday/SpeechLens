#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/release.sh --version <version>" >&2
}

version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      version="$2"
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

[[ -n "$version" ]] || { usage; exit 2; }

required=(
  DEVELOPER_ID_APPLICATION
  APPLE_TEAM_ID
  SENTRY_DSN
  SENTRY_AUTH_TOKEN
  SENTRY_ORG
  SENTRY_PROJECT
)
for var in "${required[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing required environment variable: $var" >&2
    exit 1
  fi
done

command -v sentry-cli >/dev/null 2>&1 || {
  echo "sentry-cli is required for release symbol upload" >&2
  exit 1
}

if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
  for var in APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      echo "Missing notarization credential: set NOTARYTOOL_PROFILE or $var" >&2
      exit 1
    fi
  done
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
release_dist="${project_root}/dist/release/${version}"
notary_dist="${release_dist}/notary"
archive_path="${release_dist}/SpeechLens.xcarchive"
export_path="${release_dist}/export"
export_options_path="${release_dist}/ExportOptions.plist"
build_number="${BUILD_NUMBER:-1}"
release_name="dev.speechlens.SpeechLens@${version}+${build_number}"
export SENTRY_URL="https://de.sentry.io/"

code_sign_keychain_setting=()
if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then
  [[ -f "$CODE_SIGN_KEYCHAIN" ]] || {
    echo "Configured signing keychain does not exist: $CODE_SIGN_KEYCHAIN" >&2
    exit 1
  }
  code_sign_keychain_setting=("CODE_SIGN_KEYCHAIN=$CODE_SIGN_KEYCHAIN")
fi

"${script_dir}/package-local.sh" --configuration release

rm -rf "$release_dist"
mkdir -p "$release_dist" "$notary_dist" "$export_path"
cp -R "${project_root}/dist/local/speechlens-cli" "$release_dist/"
cp "${project_root}/Config/ExportOptions.plist" "$export_options_path"
/usr/libexec/PlistBuddy -c "Add :teamID string ${APPLE_TEAM_ID}" "$export_options_path"
/usr/libexec/PlistBuddy -c "Add :signingCertificate string ${DEVELOPER_ID_APPLICATION}" "$export_options_path"

echo "Archiving the Xcode-owned app..."
xcodebuild \
  -project "${project_root}/SpeechLens.xcodeproj" \
  -scheme SpeechLens \
  -configuration Release \
  -archivePath "$archive_path" \
  -destination "generic/platform=macOS" \
  -skipPackagePluginValidation \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  SENTRY_DSN="$SENTRY_DSN" \
  SENTRY_ENVIRONMENT=production \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  ${code_sign_keychain_setting[@]+"${code_sign_keychain_setting[@]}"} \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  archive

dsym_path="${archive_path}/dSYMs/SpeechLens.app.dSYM"
[[ -d "$dsym_path" ]] || {
  echo "Archived SpeechLens dSYM is missing: $dsym_path" >&2
  exit 1
}

echo "Creating Sentry release and uploading debug symbols..."
if ! sentry-cli releases info \
  --org "$SENTRY_ORG" \
  --project "$SENTRY_PROJECT" \
  "$release_name" >/dev/null 2>&1; then
  sentry-cli releases new \
    --org "$SENTRY_ORG" \
    --project "$SENTRY_PROJECT" \
    "$release_name"
fi
sentry-cli debug-files upload \
  --org "$SENTRY_ORG" \
  --project "$SENTRY_PROJECT" \
  --wait \
  "${archive_path}/dSYMs"
sentry-cli releases finalize \
  --org "$SENTRY_ORG" \
  --project "$SENTRY_PROJECT" \
  "$release_name"

echo "Exporting the Developer ID archive..."
xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options_path" \
  ${code_sign_keychain_setting[@]+"${code_sign_keychain_setting[@]}"}

app_bundle="${export_path}/SpeechLens.app"
[[ -d "$app_bundle" ]] || {
  echo "Exported app is missing: $app_bundle" >&2
  exit 1
}
/usr/bin/ditto "$app_bundle" "${release_dist}/SpeechLens.app"

app_bundle="${release_dist}/SpeechLens.app"
cli_binary="${release_dist}/speechlens-cli/speechlens-cli"
cli_ffmpeg="${release_dist}/speechlens-cli/ffmpeg"
cli_ffprobe="${release_dist}/speechlens-cli/ffprobe"
app_ffmpeg="${app_bundle}/Contents/MacOS/ffmpeg"
app_ffprobe="${app_bundle}/Contents/MacOS/ffprobe"
app_metallib="${app_bundle}/Contents/MacOS/Resources/mlx.metallib"
cli_metallib="${release_dist}/speechlens-cli/mlx.metallib"
app_notary_zip="${notary_dist}/SpeechLens-${version}-app-notary.zip"
app_dmg="${release_dist}/SpeechLens-${version}.dmg"
cli_zip="${release_dist}/speechlens-cli-${version}.zip"
checksums_file="${release_dist}/checksums.txt"

cat > "${release_dist}/speechlens-cli/README.txt" <<'README'
SpeechLens CLI
==============

This archive contains speechlens-cli, its unified FFmpeg/FFprobe media helpers, and the MLX
metallib loaded at runtime. Keep these files in the same directory.

Model weights are not bundled. Provide converted MLX weights with:

  speechlens-cli --weights /path/to/model_mlx.safetensors --input in.wav --output out.wav

The CLI also checks SPEECHLENS_WEIGHTS and the app model cache.
README

echo "Signing the separately packaged CLI..."
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$cli_ffmpeg"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$cli_ffprobe"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$cli_metallib"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$cli_binary"

echo "Verifying Xcode archive and nested signatures..."
codesign --verify --deep --strict --verbose=2 "$app_bundle"
codesign --verify --strict --verbose=2 "$app_ffmpeg"
codesign --verify --strict --verbose=2 "$app_ffprobe"
codesign --verify --strict --verbose=2 "$app_metallib"
app_entitlements="$(codesign -d --entitlements :- "$app_bundle" 2>/dev/null || true)"
if grep -Fq "com.apple.security.app-sandbox" <<<"$app_entitlements"; then
  echo "Release app unexpectedly enables App Sandbox" >&2
  exit 1
fi
app_signature="$(codesign -d --verbose=4 "$app_bundle" 2>&1)"
if ! grep -Fq "runtime" <<<"$app_signature"; then
  echo "Release app is missing Hardened Runtime" >&2
  exit 1
fi
codesign --verify --strict --verbose=2 "$cli_binary"
codesign --verify --strict --verbose=2 "$cli_ffmpeg"
codesign --verify --strict --verbose=2 "$cli_ffprobe"
codesign --verify --strict --verbose=2 "$cli_metallib"

notary_submit() {
  local artifact="$1" result status id
  local -a auth
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    auth=(--keychain-profile "$NOTARYTOOL_PROFILE")
  else
    auth=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
  fi
  result="$(xcrun notarytool submit "$artifact" "${auth[@]}" --wait --timeout 45m --output-format json)" || true
  echo "$result"
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${auth[@]}" >&2 || true; fi
    echo "Notarization failed for $artifact (status: ${status:-unknown})" >&2
    exit 1
  fi
}

echo "Creating app notarization archive..."
rm -f "$app_notary_zip" "$app_dmg" "$cli_zip" "$checksums_file"
ditto -c -k --keepParent "$app_bundle" "$app_notary_zip"

echo "Submitting app for notarization..."
notary_submit "$app_notary_zip"
xcrun stapler staple "$app_bundle"
xcrun stapler validate "$app_bundle"

echo "Creating DMG..."
"${script_dir}/create-dmg.sh" \
  --app "$app_bundle" \
  --output "$app_dmg" \
  --volume-name "SpeechLens ${version}"

echo "Signing DMG..."
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app_dmg"
codesign --verify --verbose=2 "$app_dmg"

echo "Submitting DMG for notarization..."
notary_submit "$app_dmg"
xcrun stapler staple "$app_dmg"
xcrun stapler validate "$app_dmg"

echo "Creating CLI notarization archive..."
ditto -c -k --keepParent "${release_dist}/speechlens-cli" "$cli_zip"

echo "Submitting CLI package for notarization..."
notary_submit "$cli_zip"

echo "Running Gatekeeper assessment..."
spctl -a -vv --type execute "$app_bundle"
# DMG assessment needs the primary-signature context; without it, spctl can
# reject a notarized and stapled disk image with "Insufficient Context".
spctl -a -vv --type open --context context:primary-signature "$app_dmg"

echo "Writing checksums..."
(
  cd "$release_dist"
  shasum -a 256 "$(basename "$app_dmg")" "$(basename "$cli_zip")" > "$checksums_file"
)

echo "Release artifacts:"
echo "  $app_dmg"
echo "  $cli_zip"
echo "  $checksums_file"
