#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache .build/Dose.iconset dist/Dose.app/Contents/MacOS dist/Dose.app/Contents/Resources
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out ".build/Dose.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/AppIcon.png --out ".build/Dose.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/Dose.iconset -o dist/Dose.app/Contents/Resources/Dose.icns
swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Core.swift Sources/CodexRefresh.swift Sources/App.swift -o dist/Dose.app/Contents/MacOS/Dose
cat > dist/Dose.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dose</string>
<key>CFBundleIdentifier</key><string>local.melkikh.dose</string>
<key>CFBundleName</key><string>Dose</string>
<key>CFBundleIconFile</key><string>Dose</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - dist/Dose.app
printf 'Built: %s/dist/Dose.app\n' "$PWD"
