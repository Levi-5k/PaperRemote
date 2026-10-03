#!/bin/zsh
# Builds the Mac app, Windows companion, and M5Paper firmware, then publishes a GitHub release
# that the in-app updaters read. Usage: scripts/publish-release.sh 1.1.0 [--no-upload] [--notes "text"]

set -euo pipefail

root="${0:A:h:h}"
repository="Levi-5k/PaperRemote"
version="${1:-}"
shift || true
upload=1
notes=""
while (( $# > 0 )); do
    case "$1" in
        --no-upload) upload=0 ;;
        --notes) notes="${2:?--notes needs text}"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "Usage: $0 <major.minor.patch> [--no-upload] [--notes \"text\"]" >&2
    exit 2
fi
tag="v$version"
if (( upload )) && gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
    echo "Release $tag already exists." >&2
    exit 1
fi
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    echo "warning: the working tree has uncommitted changes; they will be included in the build." >&2
fi

echo "==> Setting version $version"
plist="$root/mac-companion/Sources/PaperGIFMac/Info.plist"
build_number=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$plist"
sed -i '' -E "s#<Version>[^<]*</Version>#<Version>$version</Version>#" "$root/windows-companion/Directory.Build.props"
sed -i '' -E "s#(-DPAPERGIF_FIRMWARE_VERSION=\\\\\")[^\\\\]*(\\\\\")#\\1$version\\2#" "$root/firmware/platformio.ini"
grep -q "<Version>$version</Version>" "$root/windows-companion/Directory.Build.props"
grep -q "PAPERGIF_FIRMWARE_VERSION=\\\\\"$version\\\\\"" "$root/firmware/platformio.ini"

output="$root/dist/$tag"
rm -rf "$output"
mkdir -p "$output"
mac_asset="paperGIF-Mac-$version.zip"
windows_asset="paperGIF-Windows-$version.zip"
firmware_asset="paperGIF-M5Paper-$version.bin"

echo "==> Building Mac app"
PAPERGIF_NO_LAUNCH=1 "$root/mac-companion/package-app.sh" release
ditto -c -k --keepParent "$root/mac-companion/.build/paperGIF Mac.app" "$output/$mac_asset"

echo "==> Building M5Paper firmware"
"$HOME/.platformio/penv/bin/pio" run -d "$root/firmware" -e m5paper-v1
cp "$root/firmware/.pio/build/m5paper-v1/firmware.bin" "$output/$firmware_asset"

echo "==> Building Windows companion"
windows_staging="$output/windows"
# LangVersion 12 matches the .NET 8 toolchain the Windows host builds with.
dotnet publish "$root/windows-companion/src/PaperGIF.Windows.Host/PaperGIF.Windows.Host.csproj" \
    --configuration Release \
    --framework net8.0-windows10.0.22621.0 \
    --runtime win-x64 \
    --self-contained false \
    --output "$windows_staging" \
    -p:EnableWindowsTargeting=true \
    -p:LangVersion=12
(cd "$windows_staging" && COPYFILE_DISABLE=1 zip -qr "$output/$windows_asset" .)
rm -rf "$windows_staging"

asset_json() {
    local file="$output/$1"
    printf '{"name":"%s","sha256":"%s","size":%s}' \
        "$1" "$(shasum -a 256 "$file" | cut -d' ' -f1)" "$(stat -f%z "$file")"
}
cat > "$output/papergif-release.json" <<EOF
{
  "version": "$version",
  "mac": $(asset_json "$mac_asset"),
  "windows": $(asset_json "$windows_asset"),
  "firmware": $(asset_json "$firmware_asset")
}
EOF
echo "==> Release files in $output"
ls -l "$output"

if (( ! upload )); then
    echo "Skipping upload (--no-upload)."
    exit 0
fi
echo "==> Publishing $tag to $repository"
gh release create "$tag" \
    --repo "$repository" \
    --title "paperGIF $version" \
    --notes "${notes:-paperGIF $version}" \
    "$output/papergif-release.json" \
    "$output/$mac_asset" \
    "$output/$windows_asset" \
    "$output/$firmware_asset"
echo "Published $tag. Commit the version changes in Info.plist, Directory.Build.props, and platformio.ini."
