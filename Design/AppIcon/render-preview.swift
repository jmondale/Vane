// Renders a flattened preview of the Vane app icon.
//
// The real icon ships as layered artwork that the system composites with
// Liquid Glass effects, so this is only an approximation for judging the
// drawing: it fakes the Icon Composer background gradient, the back layer's
// opacity, and the rounded-rect mask.
//
// Run from this directory:  swift render-preview.swift

import AppKit

/// Opacity to apply to the cardinal cross, matching the value to set on that
/// layer in Icon Composer.
let crossOpacity: CGFloat = 0.4

/// Mirrors the geometry in 1-cardinal-cross.svg and 2-vane-arrow.svg. Both
/// shapes are symmetric about the vane axis, so AppKit's y-up coordinates give
/// the same result as the SVGs' y-down coordinates under a +45 degree rotation.
func drawIcon(side: CGFloat) {
    let scale = side / 1024

    // Later calls apply first to the point, so each transform below reads
    // bottom-up: rotate about the canvas centre, then scale to the output
    // size. Composing these with append() instead silently reverses that
    // order and throws the rotated artwork off-canvas at any scale below 1.
    let scaleOnly: AffineTransform = {
        let builder = NSAffineTransform()
        builder.scaleX(by: scale, yBy: scale)
        return builder as AffineTransform
    }()

    let scaledRotation: AffineTransform = {
        let builder = NSAffineTransform()
        builder.scaleX(by: scale, yBy: scale)
        builder.translateX(by: 512, yBy: 512)
        builder.rotate(byDegrees: 45)
        builder.translateX(by: -512, yBy: -512)
        return builder as AffineTransform
    }()

    // Layer 1: the cardinal cross, axis-aligned and translucent.
    let crossColor = NSColor.white.withAlphaComponent(crossOpacity)
    crossColor.setFill()
    for rect in [
        NSRect(x: 467, y: 230, width: 90, height: 564),
        NSRect(x: 230, y: 467, width: 564, height: 90)
    ] {
        let bar = NSBezierPath(roundedRect: rect, xRadius: 27, yRadius: 27)
        bar.transform(using: scaleOnly)
        bar.fill()
    }

    // Layer 2: the vane arrow, on the diagonal and opaque.
    let vane = NSBezierPath()
    let points = [
        NSPoint(x: 885, y: 512),
        NSPoint(x: 680, y: 398), NSPoint(x: 680, y: 474),
        NSPoint(x: 330, y: 474), NSPoint(x: 210, y: 336),
        NSPoint(x: 210, y: 688), NSPoint(x: 330, y: 550),
        NSPoint(x: 680, y: 550), NSPoint(x: 680, y: 626)
    ]
    vane.move(to: points[0])
    for point in points.dropFirst() { vane.line(to: point) }
    vane.close()
    vane.lineJoinStyle = .round
    vane.lineWidth = 20 * scale
    vane.transform(using: scaledRotation)

    NSColor.white.setFill()
    NSColor.white.setStroke()
    vane.fill()
    vane.stroke()
}

func renderIcon(side: CGFloat, to name: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { print("FAIL: no bitmap rep"); return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225).addClip()

    // The clear-sky pair from ConditionStyle.accentColors(isDaytime:).
    NSGradient(colors: [
        NSColor.systemBlue.usingColorSpace(.sRGB)!,
        NSColor.systemCyan.usingColorSpace(.sRGB)!
    ])!.draw(in: rect, angle: -90)

    drawIcon(side: side)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { print("FAIL: no png"); return }
    do {
        try png.write(to: URL(fileURLWithPath: name))
        print("wrote \(name) at \(Int(side))px")
    } catch {
        print("FAIL: \(error.localizedDescription)")
    }
}

renderIcon(side: 1024, to: "preview.png")
renderIcon(side: 128, to: "preview-128.png")
renderIcon(side: 32, to: "preview-32.png")
