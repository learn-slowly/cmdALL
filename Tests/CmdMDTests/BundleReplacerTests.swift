import XCTest
@testable import CmdMD

/// 앱 번들 교체 — 성공/실패 원복/권한 없음. 가짜 .app 디렉터리로 검증한다.
final class BundleReplacerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("replacer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        // 권한 테스트가 0555로 만들어 둔 폴더도 지울 수 있게 되돌린다.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// marker 파일 하나를 담은 가짜 .app 디렉터리를 만든다.
    @discardableResult
    private func makeApp(_ url: URL, marker: String) -> URL {
        let contents = url.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try? marker.write(to: contents.appendingPathComponent("marker.txt"),
                          atomically: true, encoding: .utf8)
        return url
    }

    private func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    func testReplacesTargetWithStagedAndDisposesBackup() throws {
        let target = makeApp(root.appendingPathComponent("cmdALL.app"), marker: "old")
        let staged = makeApp(root.appendingPathComponent("staged/cmdALL.app"), marker: "new")

        var disposed: [URL] = []
        try BundleReplacer.replace(staged: staged, target: target,
                                   fileManager: .default,
                                   disposeBackup: {
                                       disposed.append($0)
                                       try FileManager.default.removeItem(at: $0)
                                   })

        XCTAssertEqual(marker(target), "new", "target에 새 번들이 놓여야 한다")
        XCTAssertEqual(disposed.count, 1, "백업이 정확히 한 번 처분돼야 한다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged는 옮겨졌어야 한다")
    }

    /// staged가 없으면 2단계에서 실패한다 — 그때 기존 앱이 제자리로 돌아와야 한다.
    func testRestoresOriginalWhenStagedMoveFails() {
        let target = makeApp(root.appendingPathComponent("cmdALL.app"), marker: "old")
        let missingStaged = root.appendingPathComponent("nope/cmdALL.app")

        XCTAssertThrowsError(
            try BundleReplacer.replace(staged: missingStaged, target: target,
                                       fileManager: .default, disposeBackup: { _ in })
        ) { error in
            guard case UpdateInstallError.replaceFailed = error else {
                return XCTFail("replaceFailed를 기대했다: \(error)")
            }
        }
        XCTAssertEqual(marker(target), "old", "기존 앱이 원복돼야 한다")
        // 백업 잔여물이 남지 않아야 한다.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix(".cmdALL-backup-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "원복 후 백업이 남으면 안 된다: \(leftovers)")
    }

    func testFailsEarlyWhenParentNotWritable() throws {
        let target = makeApp(root.appendingPathComponent("cmdALL.app"), marker: "old")
        let staged = makeApp(root.appendingPathComponent("staged/cmdALL.app"), marker: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        XCTAssertThrowsError(
            try BundleReplacer.replace(staged: staged, target: target,
                                       fileManager: .default, disposeBackup: { _ in })
        ) { error in
            guard case UpdateInstallError.noWritePermission = error else {
                return XCTFail("noWritePermission을 기대했다: \(error)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(marker(target), "old", "아무것도 바뀌지 않아야 한다")
    }
}
