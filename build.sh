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
  "$project_dir/Sources/RegionOCR.swift" "$build_dir/generated/EngineConfiguration.swift" \
  -o "$build_dir/TranslateGPT"
app_dir="$build_dir/TranslateGPT.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/TranslateGPT" "$app_dir/Contents/MacOS/TranslateGPT"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$build_dir/generated/SafariDOMBridge.js" "$app_dir/Contents/Resources/SafariDOMBridge.js"
codesign --force --timestamp=none --sign "${TRANSLATEGPT_SIGN_IDENTITY:--}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
