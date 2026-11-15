#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/build"
config_path="${TRANSLATEGPT_CONFIG:-$project_dir/config/Engine.local.json}"
module_cache="${TMPDIR:-/tmp}/TranslateGPT-swift-cache"
if [[ ! -f "$config_path" ]]; then
  echo 'Missing local configuration. Copy config/Engine.example.json to config/Engine.local.json and set your existing ChatGPT conversation URL.' >&2
  exit 1
fi
mkdir -p "$build_dir" "$module_cache"
python3 "$project_dir/scripts/prepare_config.py" "$config_path" "$build_dir/generated"
xcrun swiftc -module-cache-path "$module_cache" -parse-as-library \
  -target "$(uname -m)-apple-macosx15.0" \
  "$project_dir/Sources/main.swift" "$project_dir/Sources/SafariChatBackend.swift" \
  "$project_dir/Sources/SafariDOMBackend.swift" "$project_dir/Sources/SelectionService.swift" \
  "$project_dir/Sources/RegionOCR.swift" "$project_dir/Sources/TranslationRendering.swift" "$project_dir/Sources/SelectionButton.swift" \
  "$build_dir/generated/EngineConfiguration.swift" \
  -o "$build_dir/TranslateGPT"
app_dir="$build_dir/TranslateGPT.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/TranslateGPT" "$app_dir/Contents/MacOS/TranslateGPT"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$build_dir/generated/SafariDOMBridge.js" "$app_dir/Contents/Resources/SafariDOMBridge.js"
# Math typesetting (Temml, MIT). Fetched and checksum-verified by scripts/fetch_temml.py; never committed.
temml_dir="$build_dir/vendor/temml"
if [[ -f "$temml_dir/temml.min.js" ]]; then
  cp "$temml_dir/temml.min.js" "$app_dir/Contents/Resources/temml.min.js"
  cp "$temml_dir/LICENSE" "$app_dir/Contents/Resources/Temml-LICENSE.txt"
  if [[ -f "$temml_dir/Temml-Local.css" ]]; then cp "$temml_dir/Temml-Local.css" "$app_dir/Contents/Resources/Temml-Local.css"; fi
elif [[ "${TRANSLATEGPT_REQUIRE_TEMML:-0}" == 1 ]]; then
  echo 'Temml is missing: run python3 scripts/fetch_temml.py first.' >&2
  exit 1
else
  echo 'Note: Temml not fetched; formulas will use the simpler fallback rendering.' >&2
fi
codesign --force --timestamp=none --sign "${TRANSLATEGPT_SIGN_IDENTITY:--}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
