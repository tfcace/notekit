#!/bin/zsh
# Builds the baseline Notes app as a .app bundle at build/Notes.app.
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build -c release --product Notes
binary_dir="$(swift build -c release --show-bin-path)"
bundle_dir="$project_dir/build/Notes.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$binary_dir/Notes" "$bundle_dir/Contents/MacOS/Notes"
cp "$project_dir/Resources/Mac-Info.plist" "$bundle_dir/Contents/Info.plist"
codesign --force --sign - "$bundle_dir"
printf '%s\n' "$bundle_dir"
