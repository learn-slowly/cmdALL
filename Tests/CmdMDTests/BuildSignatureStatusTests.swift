import XCTest
@testable import CmdMD

/// `codesign -d -r-` 출력 분류 로직만 검증한다(라이브 `SecCode` 호출은 관례대로
/// 자동 테스트 대상 밖 — `current()`는 실행 중인 프로세스에 좌우돼 결정적이지 않다).
/// 2026-07-30 opus 자문: 앱이 스스로 ad-hoc 서명 상태를 알아채 사용자에게 미리
/// 알려주면, "또 권한이 풀렸다"는 증상만 겪던 문제를 원인이 보이는 상태로 바꾼다.
final class BuildSignatureStatusTests: XCTestCase {
    func testClassifiesStableIdentityFromCertificateLeaf() {
        let text = #"identifier "work.cmdspace.cmddocu" and certificate leaf = H"2148014c5ef9e847693bd352bc135d38360c52a4""#
        XCTAssertEqual(BuildSignatureStatus.classify(designatedRequirement: text), .stableIdentity)
    }

    func testClassifiesAdHocFromCdhash() {
        let text = #"identifier "work.cmdspace.cmddocu" and cdhash H"fe030045504c5c855cdb54394b10b29291e1a6b""#
        XCTAssertEqual(BuildSignatureStatus.classify(designatedRequirement: text), .adHoc)
    }

    func testClassifiesUnknownForUnrecognizedText() {
        XCTAssertEqual(BuildSignatureStatus.classify(designatedRequirement: "anchor apple"), .unknown)
    }

    func testClassifiesUnknownForEmptyText() {
        XCTAssertEqual(BuildSignatureStatus.classify(designatedRequirement: ""), .unknown)
    }
}
