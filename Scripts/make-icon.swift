// 產生 App 圖示。用法：swift Scripts/make-icon.swift <輸出的 1024×1024 PNG 路徑>
// 圖示內容是四條垂直推桿，呼應選單列的圖示與這個 App 的用途。由 Scripts/make-icon.sh 呼叫。
import AppKit
import SwiftUI

let size: CGFloat = 1024
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("需要輸出路徑\n".data(using: .utf8)!)
    exit(1)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

// macOS 圖示的標準版面：1024 的畫布裡放 824 的圓角方塊，四周留給陰影。
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = Path(roundedRect: plate, cornerRadius: 185, style: .continuous).cgPath

// 底板的陰影
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.32))
context.addPath(platePath)
context.setFillColor(color(0, 0, 0))
context.fillPath()
context.restoreGState()

// 底板的漸層
context.saveGState()
context.addPath(platePath)
context.clip()
let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0.13, 0.13, 0.15), color(0.04, 0.04, 0.05), color(0, 0, 0)] as CFArray,
    locations: [0, 0.5, 1]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY),
    options: []
)
// 上緣一點點高光，讓底板不要太平
let highlight = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(1, 1, 1, 0.07), color(1, 1, 1, 0)] as CFArray, locations: [0, 1]
)!
context.drawLinearGradient(
    highlight,
    start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.maxY - 320),
    options: []
)
context.restoreGState()

// 黑色底板放在深色背景（深色模式的 Dock、Finder）上會糊成一片，加一圈很淡的邊線把輪廓帶出來。
context.saveGState()
context.addPath(platePath)
context.clip()
context.addPath(platePath)
context.setStrokeColor(color(1, 1, 1, 0.14))
context.setLineWidth(6) // 一半在裁切範圍外，實際看到 3 px
context.strokePath()
context.restoreGState()

// 四條推桿：軌道、推到的位置以下填滿、圓形的推鈕。
// 顏色由左到右從青色漸變到粉紅，每條各自由下往上稍微變亮。
let sliderColors: [(CGFloat, CGFloat, CGFloat)] = [
    (0.16, 0.86, 1.00), // 青
    (0.33, 0.56, 1.00), // 藍
    (0.62, 0.42, 1.00), // 紫
    (1.00, 0.36, 0.72), // 粉紅
]
let levels: [CGFloat] = [0.34, 0.72, 0.50, 0.84]
let trackWidth: CGFloat = 46
let trackHeight: CGFloat = 500
let spacing: CGFloat = 150
let knobRadius: CGFloat = 54
let trackBottom = plate.midY - trackHeight / 2
let firstX = plate.midX - spacing * CGFloat(levels.count - 1) / 2

for (index, level) in levels.enumerated() {
    let x = firstX + spacing * CGFloat(index)
    let track = CGRect(x: x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackHeight)
    context.addPath(CGPath(roundedRect: track, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil))
    context.setFillColor(color(1, 1, 1, 0.11))
    context.fillPath()

    let knobY = trackBottom + trackHeight * level
    let filled = CGRect(x: track.minX, y: trackBottom, width: trackWidth, height: knobY - trackBottom)
    let filledPath = CGPath(roundedRect: filled, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil)
    let (r, g, b) = sliderColors[index % sliderColors.count]

    // 先畫一層同色的光暈，再疊上漸層本體。
    context.saveGState()
    context.setShadow(offset: .zero, blur: 46, color: color(r, g, b, 0.55))
    context.addPath(filledPath)
    context.setFillColor(color(r, g, b))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(filledPath)
    context.clip()
    let fill = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(r * 0.72, g * 0.72, b * 0.72), color(r, g, b)] as CFArray, locations: [0, 1]
    )!
    context.drawLinearGradient(
        fill, start: CGPoint(x: x, y: trackBottom), end: CGPoint(x: x, y: knobY), options: []
    )
    context.restoreGState()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0, 0, 0, 0.6))
    context.addEllipse(in: CGRect(x: x - knobRadius, y: knobY - knobRadius, width: knobRadius * 2, height: knobRadius * 2))
    context.setFillColor(color(1, 1, 1))
    context.fillPath()
    context.restoreGState()
}

let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
