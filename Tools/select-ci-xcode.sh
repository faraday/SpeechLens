#!/usr/bin/env bash
set -euo pipefail

candidates=(
  "/Applications/Xcode_26.6.app"
  "/Applications/Xcode_26.5.app"
  "/Applications/Xcode_26.4.1.app"
  "/Applications/Xcode_26.4.app"
  "/Applications/Xcode_26.3.app"
  "/Applications/Xcode_26.2.app"
  "/Applications/Xcode_26.1.1.app"
  "/Applications/Xcode_26.1.app"
  "/Applications/Xcode_26.0.1.app"
  "/Applications/Xcode_26.0.app"
  "/Applications/Xcode.app"
)

swift_version_for_xcode() {
  local developer_dir="$1"
  local version_output

  version_output="$(DEVELOPER_DIR="$developer_dir" xcrun swift --version 2>/dev/null)" || return 1
  sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' <<< "$version_output" | head -n 1
}

is_supported_swift() {
  local swift_version="$1"
  local swift_major swift_minor swift_patch

  IFS=. read -r swift_major swift_minor swift_patch <<< "$swift_version"
  (( swift_major > 6 || (swift_major == 6 && swift_minor >= 3) ))
}

xcode_app=""
swift_version=""
for candidate in "${candidates[@]}"; do
  if [[ ! -d "$candidate" ]]; then
    continue
  fi

  candidate_swift_version="$(swift_version_for_xcode "${candidate}/Contents/Developer")" || candidate_swift_version=""
  if [[ -n "$candidate_swift_version" ]] && is_supported_swift "$candidate_swift_version"; then
    xcode_app="$candidate"
    swift_version="$candidate_swift_version"
    break
  fi

  echo "Skipping ${candidate}: Swift ${candidate_swift_version:-unknown}; SpeechLens requires Swift 6.3 or newer." >&2
done

if [[ -z "$xcode_app" ]]; then
  echo "No Xcode installation with Swift 6.3 or newer found under /Applications." >&2
  exit 1
fi

sudo xcode-select -s "${xcode_app}/Contents/Developer"
xcodebuild -version
swift_version_output="$(swift --version)"
echo "$swift_version_output"
selected_swift_version="$(sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' <<< "$swift_version_output" | head -n 1)"

if [[ -z "$selected_swift_version" ]] || ! is_supported_swift "$selected_swift_version"; then
  echo "SpeechLens requires Swift 6.3 or newer; selected Swift ${selected_swift_version:-unknown}." >&2
  exit 1
fi
