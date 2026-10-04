#!/bin/zsh

set -euo pipefail

root="${0:A:h}"
configuration="${1:-debug}"
app="$root/.build/paperGIF Mac.app"
contents="$app/Contents"
executable="$contents/MacOS/PaperGIFMac"
matter_executable="$contents/MacOS/PaperGIFModule-matter"
resources="$contents/Resources"
module_resources="$resources/Modules"

swift build --package-path "$root" --configuration "$configuration"
bin_path=$(swift build --package-path "$root" --configuration "$configuration" --show-bin-path)

pkill -x PaperGIFMac 2>/dev/null || true

mkdir -p "$contents/MacOS" "$resources"
install -m 755 "$bin_path/PaperGIFMac" "$executable"
install -m 755 "$bin_path/PaperGIFModule-matter" "$matter_executable"
install -m 644 "$root/Sources/PaperGIFMac/Info.plist" "$contents/Info.plist"
rm -rf "$module_resources"
mkdir -p "$module_resources"
install -m 644 "$root/../modules/matter-switch.json" "$module_resources/matter-switch.json"
rm -rf "$resources/MatterPAA"
mkdir -p "$resources/MatterPAA"
install -m 644 "$root"/MatterPAA/*.der "$resources/MatterPAA/"
rm -rf "$app/PaperGIFMac_PaperGIFMac.bundle"
rm -rf "$resources/PaperGIFMac_PaperGIFMac.bundle"
ditto "$bin_path/PaperGIFMac_PaperGIFMac.bundle" "$resources/PaperGIFMac_PaperGIFMac.bundle"

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

codesign --force --sign "$identity" --identifier human-programs.paperGIFMac.module.matter "$matter_executable"
codesign --force --sign "$identity" --identifier human-programs.paperGIFMac "$app"
if [[ -z "${PAPERGIF_NO_LAUNCH:-}" ]]; then
    open "$app"
fi
echo "$app"