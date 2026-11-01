#!/bin/zsh
# Builds Reel Editor.app from the Swift package and installs it to ~/Applications.
#   ./build.sh            release build, install, open
#   ./build.sh --no-open  build and install only
# The MCP server ships inside the app: ~/Applications/Reel Editor.app/Contents/MacOS/reel-mcp
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP="build/Reel Editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ReelEditor" "$APP/Contents/MacOS/ReelEditor"
cp "$BIN/reel-mcp" "$APP/Contents/MacOS/reel-mcp"
cp Resources/transcribe_whisperx.py "$APP/Contents/Resources/"
# The build stamp every log line in the _dump folder carries, so a QA pass knows which build wrote it.
printf '{"built":"%s","git":"%s"}\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$(git rev-parse --short HEAD 2>/dev/null || echo none)" > "$APP/Contents/Resources/build.json"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Inter and Phosphor, the web app's type and icons, registered by the app at launch (Design.swift).
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# Brand marks drawn in the interface (the Claude logo on the MCP pill), copied from public/reel-animations/brands.
cp -R Resources/Brand "$APP/Contents/Resources/Brand"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Reel Editor</string>
  <key>CFBundleDisplayName</key><string>Reel Editor</string>
  <key>CFBundleIdentifier</key><string>com.sankalpsinha.reeleditor</string>
  <key>CFBundleExecutable</key><string>ReelEditor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.sankalpsinha.reeleditor</string>
      <key>CFBundleURLSchemes</key><array><string>reeleditor</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.mpeg-4</string><string>com.apple.quicktime-movie</string><string>com.apple.m4v-video</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Signed with the same identity every time (the Apple Development certificate when there is one), so macOS keeps the
# folder permissions it was given (Downloads, Movies) across rebuilds. An ad hoc signature changes with every build,
# and macOS then asks again on every launch.
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/reel-mcp"
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "No signing certificate found, signed ad hoc: macOS will ask for folder access again after each rebuild"
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Reel Editor.app"
cp -R "$APP" "$HOME/Applications/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Reel Editor.app" || true
echo "Installed $HOME/Applications/Reel Editor.app"
echo "MCP server: $HOME/Applications/Reel Editor.app/Contents/MacOS/reel-mcp"
[[ "${1:-}" == "--no-open" ]] || open "$HOME/Applications/Reel Editor.app"
