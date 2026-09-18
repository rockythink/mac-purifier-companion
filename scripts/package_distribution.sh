#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${MACFANLINK_VERSION:-1.5.1}"
DIST="$ROOT/dist"
APP="$DIST/MacFanLink.app"
BUILD_ROOT="$ROOT/.build/distribution-package"
DMG="$DIST/Mac-Purifier-Companion-$VERSION-arm64.dmg"
SOURCE_ZIP="$DIST/Mac-Purifier-Companion-$VERSION-source.zip"
SOURCE_ROOT="$BUILD_ROOT/Mac-Purifier-Companion-$VERSION-source"
DMG_ROOT="$BUILD_ROOT/dmg"

"$ROOT/scripts/build_app.sh"

if [[ -d "$BUILD_ROOT" ]]; then
    /bin/chmod -R u+w "$BUILD_ROOT"
fi
rm -rf "$BUILD_ROOT" "$DMG" "$SOURCE_ZIP"
mkdir -p "$SOURCE_ROOT/Sources/MacFanLink" "$SOURCE_ROOT/scripts" \
    "$SOURCE_ROOT/Resources" "$SOURCE_ROOT/third_party" "$SOURCE_ROOT/tests"

# This is an explicit source whitelist. It intentionally cannot capture .git,
# .local, .venv, build output, credentials, state, or temporary QR images.
for file in Package.swift pyproject.toml uv.lock LICENSE REQUIREMENTS.md .gitignore; do
    [[ -f "$ROOT/$file" ]] || { printf 'error: required source file missing: %s\n' "$file" >&2; exit 1; }
    /usr/bin/ditto "$ROOT/$file" "$SOURCE_ROOT/$file"
done
for target in MacFanLink FanControlProtocol FanHelper; do
    mkdir -p "$SOURCE_ROOT/Sources/$target"
    while IFS= read -r -d '' source; do
        /usr/bin/ditto "$source" "$SOURCE_ROOT/Sources/$target/$(basename "$source")"
    done < <(find "$ROOT/Sources/$target" -maxdepth 1 -type f -name '*.swift' -print0)
done
while IFS= read -r -d '' script; do
    /usr/bin/ditto "$script" "$SOURCE_ROOT/scripts/$(basename "$script")"
done < <(find "$ROOT/scripts" -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' \) -print0)

while IFS= read -r -d '' test_source; do
    /usr/bin/ditto "$test_source" "$SOURCE_ROOT/tests/$(basename "$test_source")"
done < <(find "$ROOT/tests" -maxdepth 1 -type f -name '*.py' -print0)
mkdir -p "$SOURCE_ROOT/tests/FanHelperTests"
while IFS= read -r -d '' test_source; do
    /usr/bin/ditto "$test_source" "$SOURCE_ROOT/tests/FanHelperTests/$(basename "$test_source")"
done < <(find "$ROOT/tests/FanHelperTests" -maxdepth 1 -type f -name '*.swift' -print0)

for resource in model-catalog.json ThirdPartyNotices.txt cc.ss-data.MacFanLink.FanHelper.plist; do
    [[ -f "$ROOT/Resources/$resource" ]] || { printf 'error: required resource missing: %s\n' "$resource" >&2; exit 1; }
    /usr/bin/ditto "$ROOT/Resources/$resource" "$SOURCE_ROOT/Resources/$resource"
done
[[ -d "$ROOT/Resources/vendor" ]] || { printf 'error: Resources/vendor is missing\n' >&2; exit 1; }
mkdir -p "$SOURCE_ROOT/Resources/vendor"
while IFS= read -r -d '' vendor_file; do
    /usr/bin/ditto "$vendor_file" "$SOURCE_ROOT/Resources/vendor/$(basename "$vendor_file")"
done < <(find "$ROOT/Resources/vendor" -maxdepth 1 -type f -name '*.py' -print0)
/usr/bin/ditto "$DIST/source-dependencies" "$SOURCE_ROOT/third_party/sources"
/usr/bin/ditto "$APP/Contents/Resources/licenses/python" "$SOURCE_ROOT/third_party/python-licenses"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SOURCE_ROOT" "$SOURCE_ZIP"

mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP" "$DMG_ROOT/MacFanLink.app"
ln -s /Applications "$DMG_ROOT/Applications"
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO \
    -volname "Mac 净化器伴侣 $VERSION" -srcfolder "$DMG_ROOT" "$DMG"

(cd "$DIST" && /usr/bin/shasum -a 256 "$(basename "$DMG")" "$(basename "$SOURCE_ZIP")") > "$DIST/SHA256SUMS"
printf 'Created installer: %s\nCreated corresponding source: %s\n' "$DMG" "$SOURCE_ZIP"
printf '%s\n' 'Notarization and stapling are intentionally left to the release operator.'
