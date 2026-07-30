import XCTest
import CryptoKit
@testable import CmdMD

/// 설치 오케스트레이션 — 네트워크·서명 검증은 가짜로 주입한다.
final class UpdateInstallerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// marker 하나를 담은 가짜 .app을 zip으로 만들어 (zip경로, sha256) 반환.
    private func makeZippedApp(marker: String) throws -> (zip: URL, hash: String) {
        let stage = root.appendingPathComponent("stage-\(UUID().uuidString)")
        let app = stage.appendingPathComponent("cmdALL.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try marker.write(to: app.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

        let zip = root.appendingPathComponent("payload-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                       stage.appendingPathComponent("cmdALL.app").path, zip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "테스트 zip 생성 실패")

        let digest = SHA256.hash(data: try Data(contentsOf: zip))
        return (zip, digest.map { String(format: "%02x", $0) }.joined())
    }

    private struct FakeFetcher: UpdateFetching {
        let zip: URL
        let sums: String
        func downloadFile(from url: URL, onProgress: @Sendable (Double) -> Void) async throws -> URL {
            onProgress(1.0)
            // 설치기가 옮겨 갈 수 있게 매번 사본을 준다.
            let copy = zip.deletingLastPathComponent()
                .appendingPathComponent("dl-\(UUID().uuidString).zip")
            try FileManager.default.copyItem(at: zip, to: copy)
            return copy
        }
        func data(from url: URL) async throws -> Data { Data(sums.utf8) }
    }

    private struct PassingVerifier: BundleVerifying {
        func verify(bundleAt url: URL, expectedVersion: String) throws {}
    }
    private struct FailingVerifier: BundleVerifying {
        func verify(bundleAt url: URL, expectedVersion: String) throws {
            throw UpdateInstallError.bundleVerificationFailed("가짜 실패")
        }
    }

    /// 테스트 기본값 — 이 컴퓨터의 실제 로그인 키체인 상태(로컬 고정 인증서 유무)에
    /// 좌우되면 안 되므로 항상 아무것도 안 하는 가짜를 명시적으로 주입한다.
    private struct NoOpSigner: BundleSigning {
        func resignWithLocalIdentityIfAvailable(bundleAt url: URL) throws {}
    }

    /// 재서명 훅이 실제로 파이프라인에 배선돼 있는지(호출 여부)만 확인하는 기록용 가짜.
    private final class RecordingSigner: BundleSigning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calledWith: URL?
        var calledWith: URL? { lock.lock(); defer { lock.unlock() }; return _calledWith }
        func resignWithLocalIdentityIfAvailable(bundleAt url: URL) throws {
            lock.lock(); _calledWith = url; lock.unlock()
        }
    }

    private func makeTarget(marker: String) -> URL {
        let target = root.appendingPathComponent("cmdALL.app")
        let contents = target.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try? marker.write(to: contents.appendingPathComponent("marker.txt"),
                          atomically: true, encoding: .utf8)
        return target
    }

    private func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    func testInstallsWhenChecksumMatches() async throws {
        let (zip, hash) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let signer = RecordingSigner()
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "\(hash)  cmdALL-macos.zip"),
            verifier: PassingVerifier(),
            signer: signer
        )

        let collector = ProgressCollector()
        try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                    targetBundle: target) { collector.add($0) }

        XCTAssertEqual(marker(target), "new", "새 번들로 교체돼야 한다")
        let seen = collector.values
        XCTAssertTrue(seen.contains(.verifying), "검증 단계를 보고해야 한다: \(seen)")
        XCTAssertTrue(seen.contains(.installing), "설치 단계를 보고해야 한다: \(seen)")
        XCTAssertNotNil(signer.calledWith, "교체 전에 로컬 인증서 재서명 훅이 호출돼야 한다(§CDHash 안정성)")
    }

    func testRejectsChecksumMismatchWithoutTouchingTarget() async throws {
        let (zip, _) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "deadbeef  cmdALL-macos.zip"),
            verifier: PassingVerifier(),
            signer: NoOpSigner()
        )

        do {
            try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                        targetBundle: target) { _ in }
            XCTFail("checksumMismatch를 기대했다")
        } catch UpdateInstallError.checksumMismatch {
            // 기대한 경로
        }
        XCTAssertEqual(marker(target), "old", "검증 실패 시 기존 앱이 그대로여야 한다")
    }

    func testRejectsWhenBundleVerificationFails() async throws {
        let (zip, hash) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "\(hash)  cmdALL-macos.zip"),
            verifier: FailingVerifier(),
            signer: NoOpSigner()
        )

        do {
            try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                        targetBundle: target) { _ in }
            XCTFail("bundleVerificationFailed를 기대했다")
        } catch UpdateInstallError.bundleVerificationFailed {
            // 기대한 경로
        }
        XCTAssertEqual(marker(target), "old", "서명 검증 실패 시 기존 앱이 그대로여야 한다")
    }

    /// 체크섬 파일에 자산 줄이 없으면 설치하지 않는다.
    func testRejectsWhenSumsMissingAsset() async throws {
        let (zip, _) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "abc  something-else.zip"),
            verifier: PassingVerifier(),
            signer: NoOpSigner()
        )
        do {
            try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                        targetBundle: target) { _ in }
            XCTFail("checksumMismatch를 기대했다")
        } catch UpdateInstallError.checksumMismatch {
            // 기대한 경로
        }
        XCTAssertEqual(marker(target), "old")
    }

    /// 작업 폴더(.cmdALL-update-*)가 남지 않아야 한다.
    func testCleansUpWorkDirectory() async throws {
        let (zip, hash) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "\(hash)  cmdALL-macos.zip"),
            verifier: PassingVerifier(),
            signer: NoOpSigner()
        )
        try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                    targetBundle: target) { _ in }

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix(".cmdALL-update-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "작업 폴더가 남으면 안 된다: \(leftovers)")
    }
}

/// 진행률 콜백은 @Sendable이라 지역 배열에 직접 담을 수 없다.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UpdateProgress] = []
    func add(_ p: UpdateProgress) { lock.lock(); storage.append(p); lock.unlock() }
    var values: [UpdateProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}
