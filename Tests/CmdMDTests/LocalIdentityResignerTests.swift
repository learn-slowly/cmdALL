import XCTest
@testable import CmdMD

/// `security find-identity -v -p codesigning` 출력에서 SHA-1 지문을 뽑는 순수 파싱
/// 로직만 검증한다(라이브 프로세스 호출은 제외 — 관례대로 자동 테스트 대상 밖).
/// 2026-07-30 opus 자문 S2: 이름 substring 매칭 대신 지문으로 서명해야 동명 인증서가
/// 두 개 이상 생겨도(정상적인 결말) ambiguous 에러 없이 안정적으로 서명된다.
final class LocalIdentityResignerTests: XCTestCase {
    func testParsesHashFromRealisticOutput() {
        let output = """
          1) 2148014C5EF9E847693BD352BC135D38360C52A4 "cmdALL Local Dev"
             1 valid identities found
        """
        XCTAssertEqual(
            LocalIdentityResigner.parseHash(fromFindIdentityOutput: output, identityName: "cmdALL Local Dev"),
            "2148014C5EF9E847693BD352BC135D38360C52A4"
        )
    }

    func testReturnsNilWhenNameNotFound() {
        let output = """
          1) AABBCCDDEEFF00112233445566778899AABBCCDD "Some Other Identity"
             1 valid identities found
        """
        XCTAssertNil(LocalIdentityResigner.parseHash(fromFindIdentityOutput: output, identityName: "cmdALL Local Dev"))
    }

    func testReturnsNilOnEmptyOutput() {
        XCTAssertNil(LocalIdentityResigner.parseHash(fromFindIdentityOutput: "", identityName: "cmdALL Local Dev"))
    }

    /// 인증서 재발급으로 동명 인증서가 두 개 생겨도(정상적인 결말) 첫 항목을 결정적으로
    /// 골라야 한다 — 이름으로 `codesign --sign`을 부르면 이 상황에서 ambiguous 에러가 난다.
    func testPicksFirstMatchWhenDuplicateNamesExist() {
        let output = """
          1) 1111111111111111111111111111111111111111 "cmdALL Local Dev"
          2) 2222222222222222222222222222222222222222 "cmdALL Local Dev"
             2 valid identities found
        """
        XCTAssertEqual(
            LocalIdentityResigner.parseHash(fromFindIdentityOutput: output, identityName: "cmdALL Local Dev"),
            "1111111111111111111111111111111111111111"
        )
    }

    /// "cmdALL Local Dev 2" 같은 유사 이름은 substring으로 오매칭되면 안 된다 — 따옴표
    /// 끝까지 정확히 일치해야 매칭한다.
    func testDoesNotMatchSimilarLongerName() {
        let output = """
          1) 3333333333333333333333333333333333333333 "cmdALL Local Dev 2"
             1 valid identities found
        """
        XCTAssertNil(LocalIdentityResigner.parseHash(fromFindIdentityOutput: output, identityName: "cmdALL Local Dev"))
    }

    func testSkipsMalformedHashLength() {
        let output = """
          1) TOOSHORT "cmdALL Local Dev"
             1 valid identities found
        """
        XCTAssertNil(LocalIdentityResigner.parseHash(fromFindIdentityOutput: output, identityName: "cmdALL Local Dev"))
    }
}
