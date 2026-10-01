#!/bin/sh
# Re-signs a built GBear.app with Apple's Virtual HID entitlement so GBear Virtual Pads work.
#
#   Scripts/sign-virtual-hid.sh build/Release/GBear.app ~/Downloads/GBear_VirtualHID.provisionprofile [identity]
#
# The profile must be for AFYV687T82.com.funnybearapps.gbear and include
# com.apple.developer.hid.virtual.device (only possible after Apple grants "Virtual HID").
# A Developer ID profile runs on any Mac; a development profile only on the Macs listed in it.
# Signing with the entitlement but without a matching embedded profile makes macOS kill GBear at
# launch (BJ-095), so this script refuses to sign unless the profile checks out.
#
# Set NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile name to notarize and staple
# a Developer ID build.
set -eu

ENTITLEMENT=com.apple.developer.hid.virtual.device
TEAM=AFYV687T82
BUNDLE_ID=com.funnybearapps.gbear

if [ $# -lt 2 ]; then
    sed -n '2,13p' "$0"
    exit 2
fi

APP=${1%/}
PROFILE=$2
IDENTITY=${3:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gbear-sign.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

[ -d "$APP/Contents/MacOS" ] || { echo "Not an app bundle: $APP" >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "Profile not found: $PROFILE" >&2; exit 1; }

security cms -D -i "$PROFILE" > "$WORK/profile.plist"
profile_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$WORK/profile.plist" 2>/dev/null || true; }

app_id=$(profile_value Entitlements:com.apple.application-identifier)
if [ "$app_id" != "$TEAM.$BUNDLE_ID" ]; then
    other=$(profile_value Entitlements:application-identifier)
    echo "Profile is for '${app_id:-$other}' ($(profile_value Platform | tr -d ' \n')); expected a macOS profile for $TEAM.$BUNDLE_ID." >&2
    exit 1
fi
if [ "$(profile_value "Entitlements:$ENTITLEMENT")" != "true" ]; then
    echo "Profile does not include $ENTITLEMENT." >&2
    echo "Enable Virtual HID on the App ID (after Apple grants it), then regenerate the profile." >&2
    exit 1
fi

expires=$(profile_value ExpirationDate)
if [ "$(profile_value ProvisionsAllDevices)" = "true" ]; then
    kind="Developer ID"
    default_identity="Developer ID Application"
else
    kind="development"
    default_identity="Apple Development"
    this_mac=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ {print $2}')
    if [ -n "$this_mac" ] && ! /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$WORK/profile.plist" 2>/dev/null | grep -q "$this_mac"; then
        echo "Warning: this Mac ($this_mac) is not in the development profile, so GBear will not launch here." >&2
    fi
    echo "Note: a development profile only runs on the Macs listed in it. Use a Developer ID profile for releases." >&2
fi
echo "Profile: $kind, expires $expires"

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' -v want="$default_identity" 'index($2, want) == 1 {print $2; exit}')
    [ -n "$IDENTITY" ] || { echo "No \"$default_identity\" signing identity in the keychain." >&2; exit 1; }
fi
echo "Identity: $IDENTITY"

ENTITLEMENTS="$WORK/GBear.entitlements"
cp "$ROOT/GBear/GBear.entitlements" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy \
    -c "Add :$ENTITLEMENT bool true" \
    -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM" \
    "$ENTITLEMENTS"

cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# Nested code first (inside-out), then the app with the entitlements.
main_exe="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
find "$APP/Contents" -depth -type f \( -perm -u+x -o -name '*.dylib' \) | while IFS= read -r file; do
    [ "$file" = "$main_exe" ] && continue
    file "$file" | grep -q 'Mach-O' || continue
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$file"
done
find "$APP/Contents" -depth -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.xpc' -o -name '*.bundle' \) | while IFS= read -r bundle; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$bundle"
done
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict "$APP"
if ! codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "$ENTITLEMENT"; then
    echo "Signed app is missing $ENTITLEMENT." >&2
    exit 1
fi
echo "Signed $APP with $ENTITLEMENT."

if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ "$kind" = "Developer ID" ] || { echo "Only Developer ID builds can be notarized." >&2; exit 1; }
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"
    xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    echo "Notarized and stapled."
fi
