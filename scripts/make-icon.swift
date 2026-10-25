#!/usr/bin/env swift
// Renders the Pitwall app icon at 1024x1024.
//   swift scripts/make-icon.swift <output.png>
// scripts/make-icon.sh turns it into the asset catalog and .icns.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip so y grows downward; easier to reason about "top of the icon".
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824pt body centered in 1024, ~185pt corner radius.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x000000, 0.45))
ctx.addPath(shape)
ctx.setFillColor(color(0x10131A))
ctx.fillPath()
ctx.restoreGState()

// Background gradient.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0x2A3142), color(0x12151D), color(0x0A0C11)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// Soft orange glow behind the pipeline.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFF8A1F, 0.22), color(0xFF8A1F, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 600), endRadius: 380, options: [])

// The notch: black slab hanging from the top edge, with rounded bottom corners.
let notch = CGRect(x: 232, y: 100, width: 560, height: 132)
let notchPath = CGMutablePath()
let r: CGFloat = 52
notchPath.move(to: CGPoint(x: notch.minX, y: notch.minY))
notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.minY))
notchPath.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY - r))
notchPath.addQuadCurve(to: CGPoint(x: notch.maxX - r, y: notch.maxY), control: CGPoint(x: notch.maxX, y: notch.maxY))
notchPath.addLine(to: CGPoint(x: notch.minX + r, y: notch.maxY))
notchPath.addQuadCurve(to: CGPoint(x: notch.minX, y: notch.maxY - r), control: CGPoint(x: notch.minX, y: notch.maxY))
notchPath.closeSubpath()
ctx.addPath(notchPath)
ctx.setFillColor(color(0x000000))
ctx.fillPath()

// Left wing: green status dot. Right wing: orange progress ring.
let wingY = notch.midY + 6
ctx.setFillColor(color(0x34D058))
ctx.fillEllipse(in: CGRect(x: notch.minX + 62, y: wingY - 24, width: 48, height: 48))

let ringCenter = CGPoint(x: notch.maxX - 86, y: wingY)
ctx.setLineWidth(13)
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.addArc(center: ringCenter, radius: 26, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0xFF9F2E))
ctx.addArc(center: ringCenter, radius: 26, startAngle: -.pi / 2, endAngle: .pi * 0.85, clockwise: false)
ctx.strokePath()

// Pipeline: done -> running -> queued.
let y: CGFloat = 600
let xs: [CGFloat] = [292, 512, 732]
ctx.setLineCap(.round)
ctx.setLineWidth(22)
ctx.setStrokeColor(color(0x34D058))
ctx.move(to: CGPoint(x: xs[0], y: y)); ctx.addLine(to: CGPoint(x: xs[1], y: y)); ctx.strokePath()
// Not reached yet: a dim stub between the running node's ring and the queued node.
ctx.setStrokeColor(color(0xFFFFFF, 0.25))
ctx.setLineWidth(16)
ctx.move(to: CGPoint(x: xs[1] + 92, y: y)); ctx.addLine(to: CGPoint(x: xs[2] - 70, y: y)); ctx.strokePath()

// Done node with a check.
ctx.setFillColor(color(0x34D058))
ctx.fillEllipse(in: CGRect(x: xs[0] - 70, y: y - 70, width: 140, height: 140))
ctx.setStrokeColor(color(0x0B2814))
ctx.setLineWidth(20)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: xs[0] - 32, y: y + 2))
ctx.addLine(to: CGPoint(x: xs[0] - 8, y: y + 26))
ctx.addLine(to: CGPoint(x: xs[0] + 34, y: y - 22))
ctx.strokePath()

// Running node: orange with a partial ring around it.
ctx.setFillColor(color(0xFF8A1F))
ctx.fillEllipse(in: CGRect(x: xs[1] - 84, y: y - 84, width: 168, height: 168))
ctx.setFillColor(color(0xFFFFFF))
let play = CGMutablePath()
play.move(to: CGPoint(x: xs[1] - 22, y: y - 36))
play.addLine(to: CGPoint(x: xs[1] + 38, y: y))
play.addLine(to: CGPoint(x: xs[1] - 22, y: y + 36))
play.closeSubpath()
ctx.addPath(play)
ctx.fillPath()
ctx.setStrokeColor(color(0xFF9F2E, 0.55))
ctx.setLineWidth(10)
ctx.addArc(center: CGPoint(x: xs[1], y: y), radius: 112, startAngle: -.pi / 2, endAngle: .pi * 0.9, clockwise: false)
ctx.strokePath()

// Queued node: hollow.
ctx.setStrokeColor(color(0xFFFFFF, 0.5))
ctx.setLineWidth(18)
ctx.strokeEllipse(in: CGRect(x: xs[2] - 58, y: y - 58, width: 116, height: 116))

// Thin top highlight on the body edge.
ctx.restoreGState()
ctx.addPath(shape)
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
