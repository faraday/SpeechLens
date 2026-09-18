#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
catalog="${project_root}/Sources/App/Localization/Localizable.xcstrings"
verification_root="$(mktemp -d /tmp/speechlens-localizations.XXXXXX)"
trap 'rm -rf "$verification_root"' EXIT

xcrun xcstringstool compile "$catalog" \
  --output-directory "$verification_root" \
  --serialization-format text

generated="${verification_root}/en.lproj/Localizable.strings"
if [[ ! -s "$generated" ]]; then
  echo "The string catalog did not compile an English localization." >&2
  exit 1
fi
if find "${project_root}/Sources/App/Localization" -name '*.strings' -print -quit \
  | grep -q .; then
  echo "Generated .strings files must not be checked in; Xcode compiles the catalog." >&2
  exit 1
fi
