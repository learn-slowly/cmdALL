import XCTest
import SwiftUI
@testable import CmdMD

/// `Color.toHex()` — `Color(hex:)`의 역변환(위키 관계도 사용자 지정 색 저장용).
final class ColorHexTests: XCTestCase {
    func testToHexRoundTripsThroughInit() {
        for hex in ["FF0000", "00FF00", "0000FF", "112233", "AABBCC"] {
            let color = Color(hex: hex)
            XCTAssertEqual(color.toHex(), hex, "\(hex) 왕복 실패")
        }
    }

    func testInitThenToHexMatchesForKnownColor() {
        XCTAssertEqual(Color(hex: "FF8800").toHex(), "FF8800")
    }
}
