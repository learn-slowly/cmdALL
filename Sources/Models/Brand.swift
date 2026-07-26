import SwiftUI
import AppKit

// MARK: - CMDS Brand Color System (cmdALL fork palette)
//
// Single source of truth for the cmdALL brand color system inside CmdMD. This
// fork uses a dusty blue palette rather than the upstream CMDSPACE CI colors.
// Light mode accent is dusty blue (#3d6a8a); dark mode accent is a lighter
// dusty blue (#7aa2c9). Everything accent-colored in the UI should resolve
// through `Color.cmdsAccent` so the whole app follows the active appearance
// automatically — with no per-call-site `colorScheme` branching.

enum CMDSBrand {
    // Light-mode accent family (dusty blue).
    static let green       = Color(hex: "3d6a8a")   // 예전 134538 — 이제 라이트모드 accent
    static let greenHover  = Color(hex: "4a7fa3")   // 예전 1a5d4b
    static let greenBright = Color(hex: "5b93b8")   // 예전 22896a
    static let greenGlow   = Color(hex: "6fabd1")   // 예전 2fb488
    static let green50     = Color(hex: "eef3f7")   // 예전 f1f7f4
    static let green100    = Color(hex: "d7e5ee")   // 예전 dcebe3
    static let green200    = Color(hex: "b3cbdc")   // 예전 bad9c9

    // Dark-mode accent family (lighter dusty blue).
    static let pink        = Color(hex: "7aa2c9")   // 예전 E985A2 — 이제 다크모드 accent
    static let pinkLight   = Color(hex: "9bb8d6")   // 예전 F4A4B8
    static let pinkDark    = Color(hex: "5f87ab")   // 예전 D16C8A
    static let pinkSoft    = Color(hex: "1f2733")   // 예전 2b1922

    // CMDS Process stage colors (used as semantic accents, e.g. routing).
    static let connect     = Color(hex: "5b82ab")   // 예전 3b82f6, 채도 낮춘 블루
    static let merge       = Color(hex: "8f7fa8")   // 예전 8b5cf6, 채도 낮춘 퍼플
    static let develop     = Color(hex: "c9975a")   // 예전 f59e0b, 톤다운 앰버(계획서 명시값)
    static let share       = Color(hex: "7a9a82")   // 예전 10b981, 채도 낮춘 세이지그린

    // Hex strings shared with the web preview CSS so the rendered document and
    // the native chrome use identical brand values.
    static let greenHex = "#3d6a8a"   // 예전 #134538
    static let pinkHex  = "#7aa2c9"   // 예전 #E985A2
}

// MARK: - Adaptive accent tokens

extension Color {
    /// The adaptive CMDS accent — Dusty Blue (#3d6a8a) in light mode, lighter Dusty Blue (#7aa2c9) in dark mode.
    /// Backed by a dynamic `NSColor`, so it re-resolves on appearance changes.
    static let cmdsAccent = Color(nsColor: .cmdsAccent)

    /// A faint tint of the accent for selected rows, hover fills, and chips.
    static let cmdsAccentSoft = Color(nsColor: .cmdsAccentSoft)

    /// Text/icon color to place ON a solid accent fill. White over light dusty blue (light),
    /// near-black over lighter dusty blue (dark) — the cmdALL `--accent-on` rule.
    static let cmdsAccentOn = Color(nsColor: .cmdsAccentOn)

    /// The CMDS green, fixed (used for brand marks / always-green affordances).
    static let cmdsGreen = CMDSBrand.green
}

extension NSColor {
    /// Dusty Blue (#3d6a8a) in light appearances, lighter Dusty Blue (#7aa2c9) in dark.
    static let cmdsAccent = NSColor(name: NSColor.Name("CMDSAccent")) { appearance in
        appearance.isDarkMode ? NSColor(hex: "7aa2c9") : NSColor(hex: "3d6a8a")
    }

    /// Translucent accent for subtle fills; alpha tuned per appearance.
    static let cmdsAccentSoft = NSColor(name: NSColor.Name("CMDSAccentSoft")) { appearance in
        appearance.isDarkMode
            ? NSColor(hex: "7aa2c9").withAlphaComponent(0.15)   // 예전 alpha 0.18 → 계획서 명시값 0.15로 변경
            : NSColor(hex: "3d6a8a").withAlphaComponent(0.12)   // 라이트 alpha는 기존 0.12 그대로 유지(계획서에 라이트 값 명시 없어 변경 없음)
    }

    /// On-accent text: white over light dusty blue (light), near-black over lighter dusty blue (dark).
    static let cmdsAccentOn = NSColor(name: NSColor.Name("CMDSAccentOn")) { appearance in
        appearance.isDarkMode ? NSColor(hex: "0b0f0d") : NSColor(hex: "ffffff")
    }

    /// Hex initializer matching `Color(hex:)` semantics (RGB / RRGGBB / AARRGGBB).
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

extension NSAppearance {
    /// True when the effective appearance is one of the dark variants.
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Brand logo

/// cmdALL 마크 색(#1c1e26 배경, #7aa2c9 ⌘, #9989c4 별표).
/// 앱 아이콘(scripts/make_icon.swift)과 동일한 리터럴을 공유한다.
/// 공유 리터럴: 배경 #1c1e26, ⌘ #7aa2c9, 별표 #9989c4,
///   SF Symbol "command", 별표 문자 "＊"(U+FF0A), ⌘ 크기 프레임 대비 82%*0.9(=73.8%, 정중앙),
///   별표는 벌레처럼 보인다는 지적(2026-07-26)으로 가운데 겹침을 폐기 — 오른쪽 아래 구석에
///   작은 점처럼(크기 30%, 중심 x=85.5%·y=14.5%, 두께 regular).
enum DocBrand {
    static let background = Color(hex: "1c1e26")
    static let command    = Color(hex: "7aa2c9")
    static let asterisk   = Color(hex: "9989c4")
}

/// cmdALL 캐노니컬 마크: ⌘ + 오른쪽 아래 구석의 작은 별표 포인트.
/// 앱 아이콘과 같은 모티프(인앱 hero용). 순수 벡터라 swift run·패키지 모두 동일.
struct BrandLogo: View {
    var size: CGFloat = 76
    /// 호환용(현재 마크는 자체 텍스트 없음 — 워드마크는 호출부에서 별도 표기).
    var showWordmark: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
            .fill(DocBrand.background)
            .frame(width: size, height: size)
            .overlay {
                ZStack {
                    Image(systemName: "command")
                        .font(.system(size: size * 0.82 * 0.9, weight: .medium))
                        .foregroundStyle(DocBrand.command)

                    Text("＊")
                        .font(.system(size: size * 0.30, weight: .regular))
                        .foregroundStyle(DocBrand.asterisk)
                        .position(x: size * 0.855, y: size * (1 - 0.145))
                }
                .frame(width: size, height: size)
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
    }
}
