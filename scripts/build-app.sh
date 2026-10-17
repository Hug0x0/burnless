#!/bin/bash
# Builds dist/Burnless.app: release engine + release SwiftUI app, ad-hoc signed.
# Requirements (development only): Xcode Command Line Tools (Swift 6), rustup.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(tr -d '\n' < VERSION)"
build_number="${BURNLESS_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "==> Building engine (Rust, ccusage)"
# Run inside engine/ so rustup applies engine/rust-toolchain.toml.
(cd engine && cargo build --release --locked)

echo "==> Building app (SwiftUI)"
swift build --package-path app -c release --disable-keychain
bin="$(swift build --package-path app -c release --show-bin-path)"

# Assemble in a fresh directory so stale files never survive a rebuild.
mkdir -p dist
staging="$(mktemp -d "$root/dist-staging.XXXXXX")"
trap 'trash "$staging" 2>/dev/null || true' EXIT
app="$staging/Burnless.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
cp "$bin/Burnless" "$app/Contents/MacOS/Burnless"
cp engine/target/release/burnless-engine "$app/Contents/Resources/burnless-engine"
ditto "$bin/Burnless_Burnless.bundle" "$app/Contents/Resources/Burnless_Burnless.bundle"
cp app/Sources/Burnless/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp engine/pricing/LITELLM-LICENSE.txt "$app/Contents/Resources/LITELLM-LICENSE.txt"

# Optional background quota collection (Settings → Background), registered
# with SMAppService.agent only when the user turns it on.
cat > "$app/Contents/Library/LaunchAgents/io.github.hug0x0.burnless.quota.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.github.hug0x0.burnless.quota</string>
<key>BundleProgram</key><string>Contents/MacOS/Burnless</string>
<key>ProgramArguments</key><array><string>Burnless</string><string>--collect-quotas</string></array>
<key>StartInterval</key><integer>60</integer>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Background</string>
<key>LowPriorityIO</key><true/>
<key>Nice</key><integer>10</integer>
<key>AssociatedBundleIdentifiers</key><array><string>io.github.hug0x0.burnless</string></array>
</dict></plist>
PLIST

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.hug0x0.burnless</string>
<key>CFBundleName</key><string>Burnless</string>
<key>CFBundleDisplayName</key><string>Burnless</string>
<key>CFBundleExecutable</key><string>Burnless</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>MIT License. Built on ccusage and Agent Burn.</string>
</dict></plist>
PLIST

identity="${BURNLESS_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" "$app/Contents/Resources/burnless-engine"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

if [[ -e dist/Burnless.app ]]; then trash dist/Burnless.app; fi
mv "$app" dist/Burnless.app
echo "Built $root/dist/Burnless.app ($version, build $build_number)"
