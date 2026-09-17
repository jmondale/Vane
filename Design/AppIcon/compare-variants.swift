// Builds a contact sheet comparing variants of the icon.
//
// Input is the real system-rendered output: each variant is compiled by actool
// from a patched copy of AppIcon.icon and expanded with iconutil, so these
// tiles carry the actual Liquid Glass treatment rather than the approximation
// in render-preview.swift.
//
// Columns show 16, 32, and 128px at true pixel size — the sizes that actually
// ship in the .icns — plus the 32px tile magnified 4x with no interpolation,
// so small-size behaviour can be inspected without guessing.
//
// Run:  swift compare-variants.swift <variant-dir> <output.png> <suffix> <v1,v2,…>
//   e.g. … /tmp/opacity-test sheet.png % 20,30,40,55
//        … /tmp/thickness-test sheet.png u 64,90,120,150
//   <variant-dir> must hold set<v>.iconset for each value listed.

import AppKit

let args = CommandLine.arguments
guard args.count == 5 else {
    print("usage: swift compare-variants.swift <variant-dir> <output.png> <suffix> <v1,v2,…>")
    exit(1)
}
let variantDirectory = args[1]
let outputPath = args[2]
let labelSuffix = args[3]
let variants = args[4].split(separator: ",").compactMap { Int($0) }

guard !variants.isEmpty else { print("FAIL: no variants parsed"); exit(1) }

/// Column layout: the true-size tiles, then a magnified view of the 32px tile.
let trueSizes = [16, 32, 128]
let magnifyFrom = 32
let magnifyScale = 4

let labelColumnWidth: CGFloat = 78
let gap: CGFloat = 18
let rowHeight: CGFloat = 146
let headerHeight: CGFloat = 30

/// `iconutil` names 32px as the @2x variant of 16px, and 256 as @2x of 128.
func fileName(forPixelSize size: Int) -> String {
    switch size {
    case 16: return "icon_16x16.png"
    case 32: return "icon_16x16@2x.png"
    case 128: return "icon_128x128.png"
    case 256: return "icon_128x128@2x.png"
    default: fatalError("no representation for \(size)px")
    }
}

func tile(variant: Int, pixelSize: Int) -> NSImage? {
    let path = "\(variantDirectory)/set\(variant).iconset/\(fileName(forPixelSize: pixelSize))"
    return NSImage(contentsOfFile: path)
}

let magnifiedWidth = CGFloat(magnifyFrom * magnifyScale)
let columnWidths = trueSizes.map(CGFloat.init) + [magnifiedWidth]
let sheetWidth = labelColumnWidth + columnWidths.reduce(0, +) + gap * CGFloat(columnWidths.count + 1)
let sheetHeight = headerHeight + rowHeight * CGFloat(variants.count)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(sheetWidth), pixelsHigh: Int(sheetHeight),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { print("FAIL: no bitmap rep"); exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// A mid grey stands in for a desktop: light enough to show the white arrow,
// dark enough that the translucent cross doesn't wash out.
NSColor(white: 0.42, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight).fill()

func draw(_ text: String, at point: NSPoint, size: CGFloat, bold: Bool = false) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
        .foregroundColor: NSColor.white
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

// Column headers, drawn along the top edge.
var headerX = labelColumnWidth + gap
for (index, width) in columnWidths.enumerated() {
    let isMagnified = index == columnWidths.count - 1
    let title = isMagnified ? "\(magnifyFrom)px @\(magnifyScale)x" : "\(Int(width))px"
    draw(title, at: NSPoint(x: headerX, y: sheetHeight - headerHeight + 8), size: 11, bold: true)
    headerX += width + gap
}

for (row, variant) in variants.enumerated() {
    let rowTop = sheetHeight - headerHeight - rowHeight * CGFloat(row)
    let centreY = rowTop - rowHeight / 2

    draw("\(variant)\(labelSuffix)", at: NSPoint(x: 16, y: centreY - 8), size: 15, bold: true)

    var x = labelColumnWidth + gap
    for (index, width) in columnWidths.enumerated() {
        let isMagnified = index == columnWidths.count - 1
        let sourceSize = isMagnified ? magnifyFrom : trueSizes[index]

        if let image = tile(variant: variant, pixelSize: sourceSize) {
            let rect = NSRect(x: x, y: centreY - width / 2, width: width, height: width)
            // Nearest-neighbour on the magnified column, so it reveals the real
            // pixels instead of inventing smooth ones.
            NSGraphicsContext.current?.imageInterpolation = isMagnified ? .none : .default
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            draw("missing", at: NSPoint(x: x, y: centreY - 6), size: 10)
        }
        x += width + gap
    }
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("FAIL: no png data"); exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(outputPath) (\(Int(sheetWidth))x\(Int(sheetHeight)))")
} catch {
    print("FAIL: \(error.localizedDescription)")
}
