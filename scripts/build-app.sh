#!/bin/bash
# Build OmitX.app — one app per architecture, never a fat binary.
#
#   ./scripts/build-app.sh                      # this Mac's architecture → build/OmitX.app
#   ./scripts/build-app.sh --arch x86_64        #                        → build/x86_64/OmitX.app
#   ./scripts/build-app.sh --arch arm64,x86_64  # two separate apps, two DMGs
#   ./scripts/build-app.sh --install            # build, then copy into /Applications
#   ./scripts/build-app.sh --dmg                # also package a DMG per architecture
#   ./scripts/build-app.sh --debug              # debug bundle → build/debug/OmitX.app;
#                                               # the only build with --window-shot / --snapshot
#
# Environment:
#   OMITX_PUBKEYS="k1:<64 hex>"     license public keys to embed (see below)
#   OMITX_API_BASE=https://…        licensing backend (default https://omitx.nviai.com)
#   OMITX_SIGN_ID="Developer ID Application: … (TEAMID)"
#                                   sign for distribution with the hardened runtime;
#                                   unset means ad-hoc signing, which only runs locally
#   OMITX_NOTARY_PROFILE=<name>     notarytool keychain profile; set it to notarize and staple
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="OmitX"
BUNDLE_ID="com.nviai.omitx"
VERSION="1.0.0"
OUT="$ROOT/build"
HOST_ARCH="$(uname -m)"

ARCHS=()
INSTALL=0
DMG=0
CONFIG=release
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            shift
            [ $# -gt 0 ] || { echo "✗ --arch needs a value: arm64, x86_64, or arm64,x86_64"; exit 1; }
            IFS=',' read -r -a parts <<< "$1"
            ARCHS+=("${parts[@]}")
            ;;
        --arch=*)
            IFS=',' read -r -a parts <<< "${1#--arch=}"
            ARCHS+=("${parts[@]}")
            ;;
        --install) INSTALL=1 ;;
        --dmg) DMG=1 ;;
        --debug) CONFIG=debug ;;
        --universal)
            echo "✗ --universal is gone: OmitX ships a separate app per architecture."
            echo "  Use --arch arm64,x86_64 to build both."
            exit 1 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# No --arch: build for this Mac, straight into build/ (what the dev workflow expects).
EXPLICIT=1
if [ ${#ARCHS[@]} -eq 0 ]; then
    ARCHS=("$HOST_ARCH")
    EXPLICIT=0
fi
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *) echo "✗ Unknown architecture '$arch' (expected arm64 or x86_64)"; exit 1 ;;
    esac
done
if [ "$CONFIG" = debug ] && [ -n "${OMITX_NOTARY_PROFILE:-}" ]; then
    echo "✗ Apple does not notarize debug builds — drop --debug or OMITX_NOTARY_PROFILE"; exit 1
fi
if [ "$INSTALL" -eq 1 ] && [[ " ${ARCHS[*]} " != *" $HOST_ARCH "* ]]; then
    echo "✗ --install needs the $HOST_ARCH build; this run only makes: ${ARCHS[*]}"
    exit 1
fi

# License-verification public keys, embedded at packaging time rather than kept in the repo.
#   OMITX_PUBKEYS="k1:<64 hex chars> k2:<hex>"   (from the backend's GET /api/v1/pubkey)
# Release builds do NOT trust the dev key, so without this variable nobody can unlock Pro.
LICENSE_KEYS=""
for pair in ${OMITX_PUBKEYS:-}; do
    kid="${pair%%:*}"
    hex="${pair#*:}"
    if [ ${#hex} -ne 64 ]; then
        echo "✗ OMITX_PUBKEYS: key '$kid' must be 64 hex characters (raw 32 bytes, not PEM)"; exit 1
    fi
    LICENSE_KEYS="$LICENSE_KEYS
        <key>$kid</key><string>$hex</string>"
done
if [ -z "$LICENSE_KEYS" ]; then
    echo "⚠ OMITX_PUBKEYS not set — this build cannot verify licenses, so every Pro feature stays locked."
fi

# The icon is identical for every architecture, so render it once.
echo "▶ Rendering the icon"
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$ICON_TMP/icon.png"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICON_TMP/AppIcon.icns"

SIGN_ID="${OMITX_SIGN_ID:-}"
ENTITLEMENTS="$ROOT/scripts/OmitX.entitlements"

build_arch() {
    local arch="$1"
    local out app bin_dir
    # A plain build lands in build/; an explicitly requested architecture gets its own folder,
    # so arm64 and x86_64 never overwrite each other.
    out="$OUT"
    if [ "$CONFIG" = debug ]; then out="$out/debug"; fi
    if [ "$EXPLICIT" -eq 1 ]; then out="$out/$arch"; fi
    app="$out/$APP_NAME.app"

    echo ""
    echo "════ $arch ════"
    echo "▶ swift build ($CONFIG, $arch)"
    swift build -c "$CONFIG" --arch "$arch"
    bin_dir="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"

    echo "▶ Packaging $app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_dir/$APP_NAME" "$app/Contents/MacOS/$APP_NAME"
    cp "$ICON_TMP/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

    # Translations: Localizable.xcstrings → <lang>.lproj/Localizable.strings(dict)
    echo "▶ Compiling translations"
    xcrun xcstringstool compile "$ROOT/Localization/Localizable.xcstrings" --output-directory "$app/Contents/Resources"
    # The source language (vi) uses the keys themselves, but vi.lproj must still exist so macOS lists Vietnamese as supported
    mkdir -p "$app/Contents/Resources/vi.lproj"
    [ -f "$app/Contents/Resources/vi.lproj/Localizable.strings" ] || echo '/* keys are the Vietnamese source strings */' > "$app/Contents/Resources/vi.lproj/Localizable.strings"
    local localizations
    localizations=$(ls "$app/Contents/Resources" | grep '\.lproj$' | sed 's/\.lproj$//' | sed 's/.*/        <string>&<\/string>/')

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
$localizations
    </array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>OmitX needs this to run cleanup commands that require administrator rights.</string>
    <key>OmitXAPIBase</key><string>${OMITX_API_BASE:-https://omitx.nviai.com}</string>
    <key>OmitXLicenseKeys</key>
    <dict>$LICENSE_KEYS
    </dict>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Lets development builds talk to a backend on 127.0.0.1; production is always HTTPS. -->
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

    # The LaunchAgent only matters for Pro builds — the community build has no --agent mode.
    if [ -d "$ROOT/Pro/Sources/OmitXPro" ]; then
        echo "▶ LaunchAgent"
        mkdir -p "$app/Contents/Library/LaunchAgents"
        cat > "$app/Contents/Library/LaunchAgents/$BUNDLE_ID.agent.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID.agent</string>
    <key>BundleProgram</key><string>Contents/MacOS/$APP_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>Contents/MacOS/$APP_NAME</string>
        <string>--agent</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$BUNDLE_ID</string>
    </array>
</dict>
</plist>
AGENT
    else
        echo "▶ Community build — skipping LaunchAgent"
    fi

    if [ -n "$SIGN_ID" ]; then
        echo "▶ Signing with $SIGN_ID"
        # --options runtime: the hardened runtime, which notarization requires.
        # --timestamp: a trusted timestamp, so the signature outlives the certificate.
        codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
                 --sign "$SIGN_ID" "$app"
        codesign --verify --strict --verbose=2 "$app"
    else
        echo "▶ Ad-hoc signing (runs on this Mac only — set OMITX_SIGN_ID to distribute)"
        codesign --force --deep --sign - "$app"
    fi

    if [ -n "${OMITX_NOTARY_PROFILE:-}" ]; then
        echo "▶ Notarizing the app (Apple usually answers in a few minutes)"
        local zip="$out/$APP_NAME-$arch-notarize.zip"
        # ditto keeps symlinks and metadata; plain zip corrupts app bundles.
        ditto -c -k --keepParent "$app" "$zip"
        xcrun notarytool submit "$zip" --keychain-profile "$OMITX_NOTARY_PROFILE" --wait
        rm -f "$zip"
        # Staple the ticket into the bundle so it opens on Macs that are offline.
        xcrun stapler staple "$app"
        xcrun stapler validate "$app"
    fi

    if [ "$DMG" -eq 1 ]; then
        echo "▶ Packaging DMG"
        # The architecture is in the filename: downloading the wrong one is the classic support ticket.
        local dmg="$OUT/$APP_NAME-$VERSION-$arch.dmg"
        if [ "$CONFIG" = debug ]; then dmg="$OUT/$APP_NAME-$VERSION-$arch-debug.dmg"; fi
        local stage
        stage="$(mktemp -d)"
        cp -R "$app" "$stage/"
        ln -s /Applications "$stage/Applications"      # drag-to-install layout
        rm -f "$dmg"
        hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
        rm -rf "$stage"
        if [ -n "$SIGN_ID" ]; then
            codesign --force --timestamp --sign "$SIGN_ID" "$dmg"
        fi
        if [ -n "${OMITX_NOTARY_PROFILE:-}" ]; then
            # The DMG is what people download, so it needs its own ticket.
            echo "▶ Notarizing the DMG"
            xcrun notarytool submit "$dmg" --keychain-profile "$OMITX_NOTARY_PROFILE" --wait
            xcrun stapler staple "$dmg"
        fi
        echo "✓ $dmg"
    fi

    if [ "$INSTALL" -eq 1 ] && [ "$arch" = "$HOST_ARCH" ]; then
        echo "▶ Installing into /Applications"
        rm -rf "/Applications/$APP_NAME.app"
        cp -R "$app" /Applications/
        echo "✓ Installed /Applications/$APP_NAME.app"
    fi

    echo "✓ Done: $app"
}

if [ -n "$SIGN_ID" ] && [ -z "${OMITX_NOTARY_PROFILE:-}" ]; then
    echo "⚠ Signed but not notarized — Gatekeeper still blocks downloads. Set OMITX_NOTARY_PROFILE."
fi
if [ -z "$SIGN_ID" ] && [ -n "${OMITX_NOTARY_PROFILE:-}" ]; then
    echo "✗ Notarization needs OMITX_SIGN_ID (Apple rejects ad-hoc signatures)"; exit 1
fi

for arch in "${ARCHS[@]}"; do
    build_arch "$arch"
done
