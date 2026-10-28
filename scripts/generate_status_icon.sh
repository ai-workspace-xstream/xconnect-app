#!/usr/bin/env bash
set -euo pipefail

# Generate macOS status bar template icons from the official Swift-Ray vector master.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG_SRC="$ROOT_DIR/assets/status_icon.svg"
STATUS_OUT="$ROOT_DIR/macos/Runner/Assets.xcassets/StatusIcon.imageset"

if [[ ! -f "$SVG_SRC" ]]; then
  echo "❌ Error: Master vector not found at $SVG_SRC" >&2
  exit 1
fi

mkdir -p "$STATUS_OUT"
echo "🍏 Generating macOS status bar icon (Swift-Ray template)..."

swift - "$SVG_SRC" "$STATUS_OUT" <<'SWIFT_CODE'
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: swift - <svg_path> <output_dir>\n", stderr)
    exit(1)
}

let svgPath = args[1]
let outputDir = args[2]

guard let svgImage = NSImage(contentsOfFile: svgPath) else {
    fputs("❌ Failed to load vector image at: \(svgPath)\n", stderr)
    exit(1)
}

func renderPNG(width: Int, height: Int, outName: String) -> Bool {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return false
    }

    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = ctx
    ctx?.imageInterpolation = .high

    svgImage.draw(
        in: NSRect(x: 0, y: 0, width: width, height: height),
        from: NSRect(origin: .zero, size: svgImage.size),
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        return false
    }

    let destURL = URL(fileURLWithPath: outputDir).appendingPathComponent(outName)
    do {
        try pngData.write(to: destURL)
        print("  ✓ Rendered \(outName) (\(width)x\(height))")
        return true
    } catch {
        fputs("❌ Write failed: \(error)\n", stderr)
        return false
    }
}

let ok1 = renderPNG(width: 18, height: 18, outName: "icon.png")
let ok2 = renderPNG(width: 36, height: 36, outName: "icon@2x.png")

if !(ok1 && ok2) {
    exit(1)
}
SWIFT_CODE

cat > "$STATUS_OUT/Contents.json" <<'EOF'
{
  "images" : [
    {
      "filename" : "icon.png",
      "idiom" : "mac",
      "scale" : "1x"
    },
    {
      "filename" : "icon@2x.png",
      "idiom" : "mac",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "✅ StatusIcon.imageset generated successfully."
