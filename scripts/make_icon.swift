#!/usr/bin/env swift
// cmd-docu(cmdALL) 앱 아이콘 생성기.
// 콘셉: 짙은 청회색 배경 + ⌘(커맨드 키) 기호(90% 크기) + 오른쪽 아래 구석에 작은 별표(＊) 포인트.
// ⌘=명령, ＊=컴퓨터에서 익숙한 "전체/와일드카드" 기호 — 두 기호로 cmdALL을 은유.
// 이 파일의 색·비율 상수는 Sources/Models/Brand.swift의 DocBrand와 값을 공유한다
// (SPM 모듈 경계 밖 독립 스크립트라 실제 코드 공유는 불가 — 값을 바꿀 때 두 곳을 함께 갱신할 것).
// 사용:
//   swift scripts/make_icon.swift <preview.png>                        # 1024 미리보기
//   swift scripts/make_icon.swift <preview.png> --colors BG,CMD,STAR    # 배경/⌘/별표 색 오버라이드(hex 3개)
//   swift scripts/make_icon.swift --install [--colors BG,CMD,STAR]      # Resources/AppIcon.icns 생성
import AppKit

func c(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// 배경 / ⌘ / 별표 색. --colors로 덮어쓸 수 있다.
var bgColor = c(0x1c1e26)
var cmdColor = c(0x7aa2c9)
var starColor = c(0x9989c4)
if let idx = CommandLine.arguments.firstIndex(of: "--colors"),
   idx + 1 < CommandLine.arguments.count {
    let hexes = CommandLine.arguments[idx + 1].split(separator: ",").compactMap { UInt32($0, radix: 16) }
    if hexes.count == 3 {
        bgColor = c(hexes[0])
        cmdColor = c(hexes[1])
        starColor = c(hexes[2])
    }
}

/// SF Symbol을 지정 색으로 칠해 rect 안에 맞춰 그린다(비율 유지, 중앙 정렬).
func drawSymbol(_ name: String, into rect: CGRect, weight: NSFont.Weight = .regular, color: NSColor = .white) {
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return }
    let sz = base.size
    let tinted = NSImage(size: sz)
    tinted.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: sz))
    color.set()
    NSRect(origin: .zero, size: sz).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let s = min(rect.width / sz.width, rect.height / sz.height)
    let w = sz.width * s, h = sz.height * s
    tinted.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
}

func makeIcon(px: Int) -> CGImage? {
    let S = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // 1) 짙은 청회색 배경, macOS 표준 squircle 모서리(비율 유지)
    let radius = S * 0.235
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                       cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.setFillColor(bgColor.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

    let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsctx

    // 2) ⌘ 기호 — 프레임의 82%*0.9(=73.8%), 중앙 배치(2026-07-26 사용자 결정 — 90%로 축소)
    let cmdSize = S * 0.82 * 0.9
    drawSymbol("command",
               into: CGRect(x: S / 2 - cmdSize / 2, y: S / 2 - cmdSize / 2, width: cmdSize, height: cmdSize),
               weight: .medium, color: cmdColor)

    // 3) 별표(＊) — 벌레처럼 보인다는 지적(2026-07-26)으로 가운데 겹침 방식을 폐기.
    //    ⌘와 겹치지 않게 오른쪽 아래 구석에 작은 점처럼, 두께는 얇게(regular).
    let starFontSize = S * 0.30
    let starFont = NSFont.systemFont(ofSize: starFontSize, weight: .regular)
    let starAttrs: [NSAttributedString.Key: Any] = [.font: starFont, .foregroundColor: starColor]
    let starStr = NSAttributedString(string: "＊", attributes: starAttrs)
    let starBounds = starStr.boundingRect(with: NSSize(width: 10000, height: 10000),
                                           options: [.usesLineFragmentOrigin])
    let starCenterX = S * 0.855
    let starCenterY = S * 0.145
    let starDrawX = starCenterX - starBounds.width / 2 - starBounds.minX
    let starDrawY = starCenterY - starBounds.height / 2 - starBounds.minY
    starStr.draw(at: NSPoint(x: starDrawX, y: starDrawY))

    NSGraphicsContext.restoreGraphicsState()

    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

if args.contains("--install") {
    let tmp = root.appendingPathComponent("dist/AppIcon.iconset")
    try? FileManager.default.removeItem(at: tmp)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let plan: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in plan {
        if let img = makeIcon(px: px) { writePNG(img, to: tmp.appendingPathComponent("\(name).png")) }
    }
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", tmp.path, "-o", icns.path]
    try? p.run(); p.waitUntilExit()
    print("wrote \(icns.path) (exit \(p.terminationStatus))")
} else {
    let out = args.count > 1 && !args[1].hasPrefix("--") ? URL(fileURLWithPath: args[1])
        : root.appendingPathComponent("dist/icon-preview.png")
    if let img = makeIcon(px: 1024) {
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        writePNG(img, to: out)
        print("wrote preview \(out.path)")
    }
}
