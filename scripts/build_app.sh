#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="MacFanLink"
BUNDLE_ID="cc.ss-data.MacFanLink"
VERSION="${MACFANLINK_VERSION:-0.1.0}"
BUILD_NUMBER="${MACFANLINK_BUILD_NUMBER:-12}"
PYTHON_SOURCE="${MACFANLINK_PYTHON_SOURCE:-}"
MACMON_SOURCE="${MACFANLINK_MACMON_SOURCE:-$(command -v macmon || true)}"
SIGN_IDENTITY="${MACFANLINK_SIGN_IDENTITY:-}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
BUILD_ROOT="$ROOT/.build/distribution"
SWIFT_BUILD="$BUILD_ROOT/swift"
PYTHON_ENV="$BUILD_ROOT/python-env"
UV="${UV:-$(command -v uv || true)}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -m)" == "arm64" ]] || fail "distribution builds require Apple Silicon"
[[ -n "$UV" && -x "$UV" ]] || fail "uv is required to reproduce the locked build environment"
if [[ -z "$PYTHON_SOURCE" ]]; then
    PYTHON_EXECUTABLE="$("$UV" python find 3.12.12)" || fail "Install the build runtime with: uv python install 3.12.12"
    PYTHON_SOURCE="$("$PYTHON_EXECUTABLE" -I -c 'import sys; print(sys.base_prefix)')"
fi
[[ -x "$PYTHON_SOURCE/bin/python3.12" ]] || fail "Python 3.12.12 runtime not found at $PYTHON_SOURCE"
[[ -x "$MACMON_SOURCE" ]] || fail "macmon 0.8.2 is required to build; set MACFANLINK_MACMON_SOURCE"
if [[ -z "$SIGN_IDENTITY" ]]; then
    while IFS= read -r identity; do
        if [[ "$identity" == *"Developer ID Application:"* && "$identity" =~ [A-Fa-f0-9]{40} ]]; then
            [[ -z "$SIGN_IDENTITY" ]] || fail "Multiple Developer ID certificates; set MACFANLINK_SIGN_IDENTITY"
            SIGN_IDENTITY="${BASH_REMATCH[0]}"
        fi
    done < <(/usr/bin/security find-identity -v -p codesigning)
    [[ -n "$SIGN_IDENTITY" ]] || fail "Set MACFANLINK_SIGN_IDENTITY to a Developer ID identity, or - for a local-only build"
fi
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(--timestamp)
fi
[[ -f "$ROOT/uv.lock" ]] || fail "uv.lock is required"
[[ -f "$ROOT/Resources/model-catalog.json" ]] || fail "Resources/model-catalog.json is required"
[[ -d "$ROOT/Resources/vendor" ]] || fail "Resources/vendor is required"

PYTHON_VERSION="$($PYTHON_SOURCE/bin/python3.12 -I -c 'import platform; print(platform.python_version())')"
[[ "$PYTHON_VERSION" == "3.12.12" ]] || fail "expected Python 3.12.12, found $PYTHON_VERSION"
[[ "$($MACMON_SOURCE --version 2>&1)" == *"0.8.2"* ]] || fail "expected macmon 0.8.2"
[[ "$(/usr/bin/file -b "$MACMON_SOURCE")" == *"arm64"* ]] || fail "macmon must be arm64"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    [[ "$(/usr/bin/security find-identity -v -p codesigning)" == *"$SIGN_IDENTITY"* ]] \
        || fail "Developer ID identity $SIGN_IDENTITY is unavailable"
fi

if [[ -d "$APP" ]]; then
    /bin/chmod -R u+w "$APP"
fi
rm -rf "$APP" "$PYTHON_ENV" "$BUILD_ROOT/python-build-standalone" "$BUILD_ROOT/smoke-data"
mkdir -p "$DIST" "$BUILD_ROOT" "$APP/Contents/MacOS" \
    "$APP/Contents/Resources/scripts" "$APP/Contents/Resources/bin" \
    "$APP/Contents/Resources/licenses/python" \
    "$APP/Contents/Library/LaunchServices" "$APP/Contents/Library/LaunchDaemons"
"$PYTHON_SOURCE/bin/python3.12" "$ROOT/scripts/prepare_source_dependencies.py"

/usr/bin/xcrun swift build \
    --package-path "$ROOT" \
    --scratch-path "$SWIFT_BUILD" \
    --configuration release \
    --triple arm64-apple-macosx14.0
SWIFT_BIN_DIR="$(/usr/bin/xcrun swift build \
    --package-path "$ROOT" \
    --scratch-path "$SWIFT_BUILD" \
    --configuration release \
    --triple arm64-apple-macosx14.0 \
    --show-bin-path)"
/usr/bin/ditto "$SWIFT_BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
/usr/bin/ditto "$SWIFT_BIN_DIR/FanHelper" "$APP/Contents/Library/LaunchServices/FanHelper"
/usr/bin/ditto "$ROOT/Resources/cc.ss-data.MacFanLink.FanHelper.plist" \
    "$APP/Contents/Library/LaunchDaemons/cc.ss-data.MacFanLink.FanHelper.plist"
/usr/bin/plutil -lint "$APP/Contents/Library/LaunchDaemons/cc.ss-data.MacFanLink.FanHelper.plist"

# Resolve only from uv.lock into an isolated build environment. Nothing in this
# environment, including its interpreter symlink, is copied into the app.
UV_PROJECT_ENVIRONMENT="$PYTHON_ENV" "$UV" sync \
    --frozen --no-dev --python "$PYTHON_SOURCE/bin/python3.12"

/usr/bin/ditto "$PYTHON_SOURCE" "$APP/Contents/Resources/runtime"
/usr/bin/install_name_tool -id @rpath/libpython3.12.dylib \
    "$APP/Contents/Resources/runtime/lib/libpython3.12.dylib"
RUNTIME_SITE="$APP/Contents/Resources/runtime/lib/python3.12/site-packages"
rm -rf "$RUNTIME_SITE"
mkdir -p "$RUNTIME_SITE"
/usr/bin/ditto "$PYTHON_ENV/lib/python3.12/site-packages" "$RUNTIME_SITE"
find "$APP/Contents/Resources/runtime" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$APP/Contents/Resources/runtime" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

for script_name in worker.py pair_device.py link_rules.py history_store.py host_metrics.py; do
    [[ -f "$ROOT/scripts/$script_name" ]] || fail "required business script missing: $script_name"
    /usr/bin/ditto "$ROOT/scripts/$script_name" "$APP/Contents/Resources/scripts/$script_name"
done
/usr/bin/ditto "$MACMON_SOURCE" "$APP/Contents/Resources/bin/macmon"
/usr/bin/ditto "$ROOT/Resources/model-catalog.json" "$APP/Contents/Resources/model-catalog.json"
mkdir -p "$APP/Contents/Resources/vendor"
while IFS= read -r -d '' vendor_file; do
    /usr/bin/ditto "$vendor_file" "$APP/Contents/Resources/vendor/$(basename "$vendor_file")"
done < <(find "$ROOT/Resources/vendor" -maxdepth 1 -type f -name '*.py' -print0)
for resource in ThirdPartyNotices.txt; do
    if [[ -f "$ROOT/Resources/$resource" ]]; then
        /usr/bin/ditto "$ROOT/Resources/$resource" "$APP/Contents/Resources/$resource"
    fi
done
if [[ -f "$ROOT/LICENSE" ]]; then
    /usr/bin/ditto "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
fi

# Preserve every installed distribution's own license text alongside the app.
"$APP/Contents/Resources/runtime/bin/python3.12" -I - "$RUNTIME_SITE" "$APP/Contents/Resources/licenses/python" <<'PY'
import importlib.metadata
import pathlib
import shutil
import sys

site = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
for distribution in importlib.metadata.distributions(path=[str(site)]):
    name = (distribution.metadata.get("Name") or "unknown").replace("/", "-")
    version = distribution.version or "unknown"
    destination = out / f"{name}-{version}"
    copied = False
    for file in distribution.files or ():
        basename = pathlib.PurePosixPath(str(file)).name.lower()
        if not (basename.startswith(("license", "copying", "notice", "copyright"))):
            continue
        source = pathlib.Path(distribution.locate_file(file))
        if source.is_file():
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination / pathlib.PurePosixPath(str(file)).name)
            copied = True
    if not copied:
        license_expression = distribution.metadata.get("License-Expression") or distribution.metadata.get("License")
        if license_expression:
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "METADATA-LICENSE.txt").write_text(license_expression.strip() + "\n")
PY

# Extract CPython's license from the verified matching source archive.
CPYTHON_ARCHIVE="$DIST/source-dependencies/python/Python-3.12.12.tgz"
mkdir -p "$APP/Contents/Resources/licenses/python/CPython-3.12.12"
/usr/bin/tar -xOf "$CPYTHON_ARCHIVE" Python-3.12.12/LICENSE \
    > "$APP/Contents/Resources/licenses/python/CPython-3.12.12/LICENSE"
RUNTIME_LICENSE_DIR="$APP/Contents/Resources/licenses/python/PythonBuildStandalone-20260211"
RUNTIME_SOURCE_DIR="$BUILD_ROOT/python-build-standalone"
mkdir -p "$RUNTIME_LICENSE_DIR" "$RUNTIME_SOURCE_DIR"
/usr/bin/tar -xzf "$DIST/source-dependencies/python/python-build-standalone-20260211.tar.gz" -C "$RUNTIME_SOURCE_DIR" --strip-components 1
while IFS= read -r -d '' runtime_license; do
    /usr/bin/ditto "$runtime_license" "$RUNTIME_LICENSE_DIR/$(basename "$runtime_license")"
done < <(find "$RUNTIME_SOURCE_DIR" -maxdepth 1 -type f -name 'LICENSE*' -print0)
/usr/bin/ditto "$RUNTIME_SOURCE_DIR/python-licenses.rst" "$RUNTIME_LICENSE_DIR/python-licenses.rst"
# Prefer an installed copy when the runtime provides one.
for runtime_license in "$PYTHON_SOURCE/LICENSE" "$PYTHON_SOURCE/LICENSE.txt"; do
    if [[ -f "$runtime_license" ]]; then
        mkdir -p "$APP/Contents/Resources/licenses/python/CPython-3.12.12"
        /usr/bin/ditto "$runtime_license" "$APP/Contents/Resources/licenses/python/CPython-3.12.12/LICENSE"
        break
    fi
done

/usr/bin/python3 - "$APP/Contents/Info.plist" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib
import sys

path, bundle_id, version, build = sys.argv[1:]
info = {
    "CFBundleDevelopmentRegion": "zh-Hans",
    "CFBundleDisplayName": "Mac 净化器伴侣",
    "CFBundleExecutable": "MacFanLink",
    "CFBundleIdentifier": bundle_id,
    "CFBundleName": "Mac 净化器伴侣",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSLocalNetworkUsageDescription": "通过局域网读取并在你启用后调节已配对的小米空气净化器。",
}
with open(path, "wb") as output:
    plistlib.dump(info, output, sort_keys=True)
PY

chmod 0755 "$APP/Contents/MacOS/$APP_NAME" \
    "$APP/Contents/Resources/runtime/bin/python3.12" \
    "$APP/Contents/Resources/bin/macmon" \
    "$APP/Contents/Library/LaunchServices/FanHelper"

# Sign leaf Mach-O files first. The sources above remain untouched.
while IFS= read -r -d '' candidate; do
    case "$candidate" in
        "$APP/Contents/MacOS/$APP_NAME") continue ;;
    esac
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
        ARCHS="$(/usr/bin/lipo -archs "$candidate")"
        if [[ "$ARCHS" != "arm64" ]]; then
            [[ " $ARCHS " == *" arm64 "* ]] || fail "Mach-O lacks arm64 slice: $candidate ($ARCHS)"
            /usr/bin/lipo "$candidate" -thin arm64 -output "$candidate.thin"
            /bin/chmod 0755 "$candidate.thin"
            /bin/mv "$candidate.thin" "$candidate"
        fi
        /usr/bin/codesign "${SIGN_FLAGS[@]}" "$candidate"
    fi
done < <(find "$APP/Contents/Resources" -type f -print0)
# Python must not add bytecode files after the bundle seal is created.
/bin/chmod -R a-w "$APP/Contents/Resources/runtime"

/usr/bin/codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID.FanHelper" "$APP/Contents/Library/LaunchServices/FanHelper"
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/$APP_NAME"
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP/Contents/Library/LaunchServices/FanHelper"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"

# Runtime checks use isolated user data and never contact or modify a purifier.
SMOKE_DATA="$BUILD_ROOT/smoke-data"
mkdir -p "$SMOKE_DATA"
MACFANLINK_DATA_DIR="$SMOKE_DATA" \
MACFANLINK_RESOURCE_DIR="$APP/Contents/Resources" \
MACFANLINK_MACMON="$APP/Contents/Resources/bin/macmon" \
"$APP/Contents/Resources/runtime/bin/python3.12" -B -E -s - <<'PY'
import colorama
import Crypto
import keyring
import miio
import PIL
import requests
print("bundled Python imports: ok")
PY
"$APP/Contents/Resources/bin/macmon" --version

printf 'Built signed app: %s\n' "$APP"
