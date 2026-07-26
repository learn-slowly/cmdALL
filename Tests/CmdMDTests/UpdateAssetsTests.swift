import XCTest
@testable import CmdMD

/// 업데이트 자산 URL 조립·체크섬 파싱·오류 문구(순수 헬퍼).
final class UpdateAssetsTests: XCTestCase {

    func testAssetAndSumsURLsUseGivenTag() {
        XCTAssertEqual(UpdateAssets.assetURL(tag: "v0.9.404").absoluteString,
                       "https://github.com/learn-slowly/cmdALL/releases/download/v0.9.404/cmdALL-macos.zip")
        XCTAssertEqual(UpdateAssets.sumsURL(tag: "v0.9.404").absoluteString,
                       "https://github.com/learn-slowly/cmdALL/releases/download/v0.9.404/SHA256SUMS.txt")
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

    /// 실사고 회귀(2026-07-25): "지금 다시 시작"이 먹통으로 보였다. 실제로는 앱이 꺼졌다
    /// 1초 안에 켜지며 탭까지 복원돼 화면이 똑같아 보인 것 — 아무 신호가 없어 사용자가
    /// 계속 다시 눌렀다. 재시작 뒤 첫 실행에서 반드시 알린다.
    func testRestartNoticeOnlyWhenMarkerMatchesCurrentVersion() {
        XCTAssertNil(UpdateAssets.restartNotice(marker: nil, currentVersion: "0.9.407"),
                     "표식이 없으면 평범한 실행 — 조용해야 한다")
        XCTAssertNil(UpdateAssets.restartNotice(marker: "", currentVersion: "0.9.407"))
        XCTAssertNil(UpdateAssets.restartNotice(marker: "0.9.406", currentVersion: "0.9.407"),
                     "표식과 실제 버전이 다르면 업데이트가 제대로 안 된 것 — 잘못 알리지 않는다")

        let notice = UpdateAssets.restartNotice(marker: "0.9.407", currentVersion: "0.9.407")
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("0.9.407"), "몇 버전이 됐는지 보여야 한다: \(notice!)")
        XCTAssertTrue(notice!.range(of: "\\p{Hangul}", options: .regularExpression) != nil,
                      "한국어 문구: \(notice!)")
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
