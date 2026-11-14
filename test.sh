#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/build/tests"
module_cache="${TMPDIR:-/tmp}/TranslateGPT-swift-cache"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--vision-check" ) ]]; then
  echo 'Usage: ./test.sh [--vision-check]' >&2
  exit 1
fi
mkdir -p "$build_dir" "$module_cache"
# Use synthetic configuration even if personal configuration exists.
python3 "$project_dir/scripts/prepare_config.py" "$project_dir/config/Engine.example.json" "$build_dir/generated"
python3 "$project_dir/Tests/config_test.py"
TRANSLATEGPT_TEST_BRIDGE_PATH="$build_dir/generated/SafariDOMBridge.js" node "$project_dir/Tests/dom_bridge_smoke.cjs"
common=(
  "$project_dir/Sources/main.swift" "$project_dir/Sources/SafariChatBackend.swift"
  "$project_dir/Sources/SafariDOMBackend.swift" "$project_dir/Sources/SelectionService.swift"
  "$project_dir/Sources/RegionOCR.swift" "$build_dir/generated/EngineConfiguration.swift"
)
for suite in CoreVerification GlobalVerification; do
  xcrun swiftc -module-cache-path "$module_cache" -D TRANSLATEGPT_TESTS -parse-as-library \
    "${common[@]}" "$project_dir/Tests/$suite.swift" -o "$build_dir/$suite"
  if [[ "$suite" == GlobalVerification && $# -eq 1 ]]; then
    "$build_dir/$suite" --vision-check
  else
    "$build_dir/$suite"
  fi
done
