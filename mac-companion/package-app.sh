#!/bin/zsh

set -euo pipefail

root="${0:A:h}"
configuration="${1:-debug}"
app="$root/.build/paperGIF Mac.app"
contents="$app/Contents"
executable="$contents/MacOS/PaperGIFMac"

swift build --package-path "$root" --configuration "$configuration"
bin_path=$(swift build --package-path "$root" --configuration "$configuration" --show-bin-path)

mkdir -p "$contents/MacOS"
install -m 755 "$bin_path/PaperGIFMac" "$executable"
install -m 644 "$root/Sources/PaperGIFMac/Info.plist" "$contents/Info.plist"

identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning |
        sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' |
        head -n 1)
fi
if [[ -z "$identity" ]]; then
    echo "No Apple Development signing identity is available." >&2
    exit 1
fi

codesign --force --sign "$identity" --identifier human-programs.paperGIFMac "$app"
open "$app"
echo "$app"