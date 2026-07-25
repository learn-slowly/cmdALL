import XCTest
@testable import CmdMD

/// 업데이트 설치 배선 — 실제 네트워크 없이 AppState 상태 전이를 검증한다.
@MainActor
final class AppUpdateInstallTests: XCTestCase {
    var dir: URL!
    var state: AppState!

    override func setUp() {
        super.setUp()
        dir = TempDataDirectory.make()
        state = AppState(dataDirectory: dir)
    }
    override func tearDown() {
        TempDataDirectory.cleanup(dir)
        super.tearDown()
    }

    func testInstallDoesNothingWithoutTag() async {
        state.updateAvailable = true
        state.latestTag = nil
        await state.startUpdateInstall()
        XCTAssertEqual(state.updateProgress, .idle, "태그가 없으면 시작하지 않는다")
    }

    func testSuccessfulInstallEndsInReadyToRelaunch() async {
        state.updateAvailable = true
        state.latestTag = "v9.9.9"
        state.latestVersion = "9.9.9"
        await state.startUpdateInstall(perform: { _, _, _, report in
            report(.downloading(fraction: 0.5))
            report(.installing)
        })
        XCTAssertEqual(state.updateProgress, .readyToRelaunch)
    }

    func testFailedInstallShowsKoreanMessage() async {
        state.updateAvailable = true
        state.latestTag = "v9.9.9"
        state.latestVersion = "9.9.9"
        await state.startUpdateInstall(perform: { _, _, _, _ in
            throw UpdateInstallError.checksumMismatch(expected: "a", actual: "b")
        })
        guard case .failed(let message) = state.updateProgress else {
            return XCTFail("failed를 기대했다: \(state.updateProgress)")
        }
        XCTAssertEqual(message, UpdateAssets.message(for: .checksumMismatch(expected: "a", actual: "b")))
    }

    func testDismissResetsProgressButKeepsUpdateAvailable() {
        state.updateAvailable = true
        state.updateProgress = .failed("어떤 오류")
        state.dismissUpdateProgress()
        XCTAssertEqual(state.updateProgress, .idle)
        XCTAssertTrue(state.updateAvailable, "알약은 계속 보여야 한다")
    }

    /// 진행 중에는 두 번째 설치가 시작되지 않아야 한다.
    func testDoesNotStartWhileBusy() async {
        state.updateAvailable = true
        state.latestTag = "v9.9.9"
        state.latestVersion = "9.9.9"
        state.updateProgress = .installing
        var ran = false
        await state.startUpdateInstall(perform: { _, _, _, _ in ran = true })
        XCTAssertFalse(ran, "진행 중이면 새 설치를 시작하지 않는다")
        XCTAssertEqual(state.updateProgress, .installing)
    }

    /// 재시작은 종료가 실제로 진행될 때만 새 인스턴스를 띄운다(취소 시 두 개가 뜨면 안 된다).
    func testRelaunchOnlyArmsPendingURL() {
        XCTAssertNil(state.pendingRelaunchBundleURL)
        state.armRelaunch(bundleURL: URL(fileURLWithPath: "/Applications/cmdALL.app"))
        XCTAssertEqual(state.pendingRelaunchBundleURL?.path, "/Applications/cmdALL.app")
    }

    /// 진행률 보고는 MainActor로 건너뛰므로 완료 뒤에 도착할 수 있다.
    /// 그때 `.readyToRelaunch`를 덮어써 "설치 중"으로 되돌리면 안 된다.
    func testLateProgressReportDoesNotClobberReadyState() async {
        let box = ReportBox()

        state.updateAvailable = true
        state.latestTag = "v9.9.9"
        state.latestVersion = "9.9.9"
        await state.startUpdateInstall(perform: { _, _, _, report in box.report = report })
        XCTAssertEqual(state.updateProgress, .readyToRelaunch)

        box.report?(.downloading(fraction: 0.1))   // 늦게 도착한 보고
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(state.updateProgress, .readyToRelaunch, "완료 후 보고는 무시돼야 한다")
    }
}

/// @Sendable 콜백을 테스트 밖으로 빼내기 위한 상자.
private final class ReportBox: @unchecked Sendable {
    var report: (@Sendable (UpdateProgress) -> Void)?
}
