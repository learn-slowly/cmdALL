import XCTest
@testable import CmdMD

/// 업데이트 자산 URL 조립·체크섬 파싱·오류 문구(순수 헬퍼).
final class UpdateAssetsTests: XCTestCase {

    func testAssetAndSumsURLsUseGivenTag() {
        XCTAssertEqual(UpdateAssets.assetURL(tag: "v0.9.404").absoluteString,
                       "https://github.com/learn-slowly/cmd-docu/releases/download/v0.9.404/cmdALL-macos.zip")
        XCTAssertEqual(UpdateAssets.sumsURL(tag: "v0.9.404").absoluteString,
                       "https://github.com/learn-slowly/cmd-docu/releases/download/v0.9.404/SHA256SUMS.txt")
    }

    /// 실제 릴리스 파일 형식: "<64 hex>␣␣<파일명>" 두 줄(zip, dmg).
    func testExpectedHashParsesRealFormat() {
        let sums = """
        8524db4e133a01e38304e3545902dee96d3de35febe484e4c84daa0eeb938ddc  cmdALL-macos.zip
        906bf1d92f085116302ff3b4ba11c508357dc23dca5881992d1d923a0f216b9c  cmdALL-0.9.403.dmg
        """
        XCTAssertEqual(UpdateAssets.expectedHash(fromSums: sums, assetName: "cmdALL-macos.zip"),
                       "8524db4e133a01e38304e3545902dee96d3de35febe484e4c84daa0eeb938ddc")
    }

    func testExpectedHashToleratesCRLFAndPathPrefixAndCase() {
        let sums = "ABCD1234  ./dist/cmdALL-macos.zip\r\nbeef  other.zip\r\n"
        XCTAssertEqual(UpdateAssets.expectedHash(fromSums: sums, assetName: "cmdALL-macos.zip"),
                       "abcd1234")
    }

    func testExpectedHashReturnsNilWhenAssetMissing() {
        XCTAssertNil(UpdateAssets.expectedHash(fromSums: "beef  other.zip", assetName: "cmdALL-macos.zip"))
        XCTAssertNil(UpdateAssets.expectedHash(fromSums: "", assetName: "cmdALL-macos.zip"))
    }

    /// 사용자에게 보이는 문구는 한국어이고, 케이스마다 구분된다.
    func testMessagesAreKoreanAndDistinct() {
        let errors: [UpdateInstallError] = [
            .noWritePermission(path: "/Applications"),
            .downloadFailed("timeout"),
            .checksumMismatch(expected: "a", actual: "b"),
            .unpackFailed("ditto 1"),
            .bundleVerificationFailed("codesign"),
            .replaceFailed("busy"),
            .replaceFailedBackupLeft(backupPath: "/Applications/.cmdALL-backup-1.app"),
        ]
        let messages = errors.map { UpdateAssets.message(for: $0) }
        XCTAssertEqual(Set(messages).count, errors.count, "케이스별 문구가 구분돼야 한다")
        for m in messages {
            XCTAssertFalse(m.isEmpty)
            XCTAssertTrue(m.range(of: "\\p{Hangul}", options: .regularExpression) != nil, "한국어 문구: \(m)")
        }
        // 백업이 남은 경우엔 경로를 그대로 실어 사용자가 Finder로 되돌릴 수 있어야 한다.
        XCTAssertTrue(UpdateAssets.message(for: .replaceFailedBackupLeft(backupPath: "/A/.b.app"))
            .contains("/A/.b.app"))
    }

    func testProgressEquatableAndBusy() {
        XCTAssertEqual(UpdateProgress.downloading(fraction: 0.5), .downloading(fraction: 0.5))
        XCTAssertNotEqual(UpdateProgress.idle, .verifying)
        XCTAssertTrue(UpdateProgress.downloading(fraction: 0).isBusy)
        XCTAssertTrue(UpdateProgress.verifying.isBusy)
        XCTAssertTrue(UpdateProgress.installing.isBusy)
        XCTAssertFalse(UpdateProgress.idle.isBusy)
        XCTAssertFalse(UpdateProgress.readyToRelaunch.isBusy)
        XCTAssertFalse(UpdateProgress.failed("x").isBusy)
    }
}
