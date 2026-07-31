import XCTest
@testable import CmdMD

/// `AppSettings.wikiGraphFolderColors` — 관계도 화면에서 레고님이 직접 고른 폴더별 색.
/// 커스텀 `init(from:)` 디코더에 decodeIfPresent 라인이 빠지면 재시작 후 조용히 기본값(빈 dict)으로
/// 되돌아가는 함정이 있어(다른 설정 필드들과 같은 관례), 라운드트립으로 미리 막는다.
final class WikiGraphFolderColorsSettingsTests: XCTestCase {
    func testDecodeFromOldSettingsWithoutKeyUsesEmptyDefault() throws {
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.wikiGraphFolderColors, [:],
                       "wikiGraphFolderColors 키가 없으면 빈 dict로 디코드돼야 한다(구 settings.json 호환)")
    }

    func testRoundTripsFolderColors() throws {
        var s = AppSettings()
        s.wikiGraphFolderColors = ["pages/논문": "FF8800", "": "112233"]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.wikiGraphFolderColors["pages/논문"], "FF8800")
        XCTAssertEqual(back.wikiGraphFolderColors[""], "112233")
        XCTAssertEqual(back.wikiGraphFolderColors.count, 2)
    }
}
