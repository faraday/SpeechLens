#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Tools/run-swift-test-xunit.sh --output <xunit.xml> [--forbid-skips] -- <swift test args...>" >&2
}

output=""
forbid_skips="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output="$2"
      shift 2
      ;;
    --forbid-skips)
      forbid_skips="true"
      shift
      ;;
    --)
      shift
      break
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

[[ -n "$output" && $# -gt 0 ]] || { usage; exit 2; }

mkdir -p "$(dirname "$output")"
log_file="$(mktemp "${TMPDIR:-/tmp}/speechlens-swift-test.XXXXXX.log")"
trap 'rm -f "$log_file"' EXIT

set +e
"$@" 2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

set +e
python3 - "$log_file" "$output" "$status" "$forbid_skips" <<'PY'
import html
import re
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
status = int(sys.argv[3])
forbid_skips = sys.argv[4] == "true"
text = log_path.read_text(encoding="utf-8", errors="replace")

case_re = re.compile(
    r"Test Case '-\[(?P<target>[^.\]]+)\.(?P<class>[^\s\]]+) (?P<method>[^\]]+)\]' "
    r"(?P<result>passed|failed|skipped) \((?P<time>[0-9.]+) seconds\)\."
)

cases = []
for match in case_re.finditer(text):
    target = match.group("target")
    class_name = match.group("class")
    method = match.group("method")
    result = match.group("result")
    cases.append(
        {
            "classname": f"{target}.{class_name}",
            "name": method,
            "time": match.group("time"),
            "failed": result == "failed",
            "skipped": result == "skipped",
        }
    )

if not cases:
    cases.append(
        {
            "classname": "SwiftPM",
            "name": "selected test run executed zero tests",
            "time": "0",
            "failed": True,
            "skipped": False,
        }
    )

failures = sum(1 for case in cases if case["failed"])
if status != 0 and failures == 0 and cases:
    cases.append(
        {
            "classname": "SwiftPM",
            "name": "swift test process",
            "time": "0",
            "failed": True,
            "skipped": False,
        }
    )

skipped_cases = [case for case in cases if case["skipped"]]
if forbid_skips and skipped_cases:
    cases.append(
        {
            "classname": "SwiftPM",
            "name": "selected test run contained forbidden skips",
            "time": "0",
            "failed": True,
            "skipped": False,
        }
    )

tests = len(cases)
failures = sum(1 for case in cases if case["failed"])
skips = sum(1 for case in cases if case["skipped"])

lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    (
        f'<testsuite name="swift-test" tests="{tests}" failures="{failures}" '
        f'errors="0" skipped="{skips}">'
    ),
]
for case in cases:
    lines.append(
        f'  <testcase classname="{html.escape(case["classname"])}" '
        f'name="{html.escape(case["name"])}" time="{html.escape(case["time"])}">'
    )
    if case["failed"]:
        lines.append('    <failure message="swift test failure"><![CDATA[')
        lines.append(text)
        lines.append("]]></failure>")
    elif case["skipped"]:
        lines.append("    <skipped/>")
    lines.append("  </testcase>")
lines.append("</testsuite>")

output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

if status != 0 or failures:
    raise SystemExit(1)
PY
report_status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi
exit "$report_status"
