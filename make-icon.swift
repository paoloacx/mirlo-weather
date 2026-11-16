// Dibuja el icono alternativo de Mirlo Weather (mirlo azul) y genera
// AppIcon.iconset + AppIcon.icns.
//
// OJO: el icono que se distribuye es el de sol/nube heredado de la app
// personal netatmo-menubar (AppIcon.icns, icono-1024.png). Si ejecutas este
// script, sobrescribe AppIcon.icns con el mirlo. El original queda guardado
// en AppIcon-mirlo.icns / AppIcon-1024-mirlo.png.
//
// Uso: swift make-icon.swift
import AppKit
import Foundation

let S: CGFloat = 1024
let INSET: CGFloat = 100
let RADIUS: CGFloat = 185

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func rotatedEllipse(center: CGPoint, rx: CGFloat, ry: CGFloat, degrees: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
    var transform = AffineTransform(translationByX: center.x, byY: center.y)
    transform.rotate(byDegrees: degrees)
    path.transform(using: transform)
    return path
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(S),
    pixelsHigh: Int(S),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let cg = context.cgContext
cg.setShouldAntialias(true)
cg.clear(CGRect(x: 0, y: 0, width: S, height: S))

let content = NSRect(x: INSET, y: INSET, width: S - INSET * 2, height: S - INSET * 2)
let squircle = NSBezierPath(roundedRect: content, xRadius: RADIUS, yRadius: RADIUS)
squircle.addClip()

// Cielo: azul profundo arriba, azul verdoso abajo.
let sky = NSGradient(colors: [
    color(0x102A46),
    color(0x1B4B6B),
    color(0x3C7F92),
])!
sky.draw(in: squircle, angle: -90)

// Halo cálido de amanecer detrás del pájaro.
let sunCenter = CGPoint(x: 560, y: 600)
let glow = NSGradient(colors: [
    color(0xF6C777, 0.55),
    color(0xF3A55E, 0.22),
    color(0xF3A55E, 0.0),
])!
glow.draw(
    fromCenter: sunCenter,
    radius: 10,
    toCenter: sunCenter,
    radius: 330,
    options: []
)

// Sol.
color(0xF8D291, 0.95).setFill()
circle(sunCenter, 118).fill()

// Nubes suaves.
func cloud(_ center: CGPoint, _ scale: CGFloat, _ alpha: CGFloat) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: -120, y: -18))
    path.curve(to: CGPoint(x: -95, y: 30), controlPoint1: CGPoint(x: -126, y: 8), controlPoint2: CGPoint(x: -120, y: 24))
    path.curve(to: CGPoint(x: -20, y: 58), controlPoint1: CGPoint(x: -76, y: 57), controlPoint2: CGPoint(x: -46, y: 62))
    path.curve(to: CGPoint(x: 80, y: 40), controlPoint1: CGPoint(x: 15, y: 76), controlPoint2: CGPoint(x: 60, y: 62))
    path.curve(to: CGPoint(x: 120, y: -2), controlPoint1: CGPoint(x: 110, y: 34), controlPoint2: CGPoint(x: 128, y: 16))
    path.curve(to: CGPoint(x: 90, y: -22), controlPoint1: CGPoint(x: 124, y: -16), controlPoint2: CGPoint(x: 110, y: -22))
    path.line(to: CGPoint(x: -90, y: -22))
    path.curve(to: CGPoint(x: -120, y: -18), controlPoint1: CGPoint(x: -110, y: -22), controlPoint2: CGPoint(x: -120, y: -21))
    path.close()

    var transform = AffineTransform(translationByX: center.x, byY: center.y)
    transform.scale(scale)
    path.transform(using: transform)

    color(0xF4F7F5, alpha).setFill()
    path.fill()
}

cloud(CGPoint(x: 300, y: 790), 0.72, 0.16)
cloud(CGPoint(x: 735, y: 835), 0.5, 0.11)

// Rama.
let branch = NSBezierPath()
branch.move(to: CGPoint(x: 205, y: 292))
branch.curve(
    to: CGPoint(x: 815, y: 322),
    controlPoint1: CGPoint(x: 390, y: 318),
    controlPoint2: CGPoint(x: 620, y: 286)
)
branch.lineWidth = 20
branch.lineCapStyle = .round
color(0x0B1A24).setStroke()
branch.stroke()

let twig = NSBezierPath()
twig.move(to: CGPoint(x: 725, y: 306))
twig.curve(
    to: CGPoint(x: 805, y: 392),
    controlPoint1: CGPoint(x: 760, y: 326),
    controlPoint2: CGPoint(x: 792, y: 358)
)
twig.lineWidth = 11
twig.lineCapStyle = .round
twig.stroke()

// Pájaro (mirlo): cola, cuerpo, cabeza, ala y pico.
let bodyColor = color(0x0C141B)
let wingColor = color(0x1B2A35)

bodyColor.setFill()
let tail = NSBezierPath()
tail.move(to: CGPoint(x: 300, y: 306))
tail.curve(
    to: CGPoint(x: 448, y: 404),
    controlPoint1: CGPoint(x: 356, y: 372),
    controlPoint2: CGPoint(x: 404, y: 396)
)
tail.line(to: CGPoint(x: 476, y: 346))
tail.curve(
    to: CGPoint(x: 312, y: 320),
    controlPoint1: CGPoint(x: 420, y: 338),
    controlPoint2: CGPoint(x: 362, y: 324)
)
tail.close()
tail.fill()

rotatedEllipse(center: CGPoint(x: 520, y: 424), rx: 138, ry: 106, degrees: -16).fill()

circle(CGPoint(x: 632, y: 522), 82).fill()

// Ala: una pluma grande y limpia.
wingColor.setFill()
let wing = NSBezierPath()
wing.move(to: CGPoint(x: 452, y: 468))
wing.curve(
    to: CGPoint(x: 596, y: 448),
    controlPoint1: CGPoint(x: 500, y: 512),
    controlPoint2: CGPoint(x: 566, y: 500)
)
wing.curve(
    to: CGPoint(x: 486, y: 372),
    controlPoint1: CGPoint(x: 590, y: 404),
    controlPoint2: CGPoint(x: 546, y: 376)
)
wing.curve(
    to: CGPoint(x: 452, y: 468),
    controlPoint1: CGPoint(x: 442, y: 368),
    controlPoint2: CGPoint(x: 424, y: 418)
)
wing.close()
wing.fill()

// Pico.
let beakColor = color(0xF09A3E)
beakColor.setFill()
let beak = NSBezierPath()
beak.move(to: CGPoint(x: 706, y: 552))
beak.line(to: CGPoint(x: 806, y: 526))
beak.line(to: CGPoint(x: 706, y: 500))
beak.close()
beak.fill()

// Ojo.
color(0xF7E7C6).setFill()
circle(CGPoint(x: 662, y: 548), 13).fill()
color(0x0C141B).setFill()
circle(CGPoint(x: 666, y: 548), 6).fill()

// Patas y dedos.
color(0xC98544).setStroke()
for x in [CGFloat(522), CGFloat(586)] {
    let leg = NSBezierPath()
    leg.move(to: CGPoint(x: x, y: 340))
    leg.line(to: CGPoint(x: x + 4, y: 300))
    leg.lineWidth = 9
    leg.lineCapStyle = .round
    leg.stroke()

    let toes = NSBezierPath()
    toes.move(to: CGPoint(x: x - 14, y: 298))
    toes.line(to: CGPoint(x: x + 4, y: 304))
    toes.line(to: CGPoint(x: x + 22, y: 298))
    toes.lineWidth = 6
    toes.lineCapStyle = .round
    toes.stroke()
}

// Brillo interior del borde.
NSGraphicsContext.restoreGraphicsState()

let border = NSBezierPath(roundedRect: content.insetBy(dx: 1, dy: 1), xRadius: RADIUS, yRadius: RADIUS)
border.lineWidth = 3
color(0xFFFFFF, 0.12).setStroke()
border.stroke()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("No se pudo generar el PNG\n", stderr)
    exit(1)
}
let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try! png.write(to: base.appendingPathComponent("AppIcon-1024.png"))

let iconset = base.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
    (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x"),
]
for (pixels, name) in sizes {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = [
        "-z", "\(pixels)", "\(pixels)",
        base.appendingPathComponent("AppIcon-1024.png").path,
        "--out", iconset.appendingPathComponent("icon_\(name).png").path,
    ]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try! task.run()
    task.waitUntilExit()
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", base.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()

print("Listo: AppIcon.icns")
