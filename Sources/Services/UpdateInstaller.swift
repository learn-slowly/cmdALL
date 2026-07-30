import Foundation
import CryptoKit

/// 네트워크 경계 — 테스트에서 가짜로 갈아끼운다.
/// `onProgress`는 델리게이트가 붙들어야 하므로 escaping이다.
protocol UpdateFetching: Sendable {
    func downloadFile(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func data(from url: URL) async throws -> Data
}

/// 번들 검증 경계(서명·버전) — 테스트에서 가짜로 갈아끼운다.
protocol BundleVerifying: Sendable {
    func verify(bundleAt url: URL, expectedVersion: String) throws
}

/// 이 컴퓨터 전용 고정 인증서("cmdALL Local Dev")가 로그인 키체인에 있으면 그걸로
/// 재서명하는 경계 — 테스트에서 가짜로 갈아끼운다. `scripts/package_app.sh`가 로컬
/// 빌드에 쓰는 것과 같은 인증서. GitHub Release(CI 빌드)는 ad-hoc 서명이라 빌드마다
/// CDHash가 달라져 그대로 설치하면 "손쉬운 사용" 권한이 재발한다(2026-07-29/30 실측,
/// §CLAUDE.md). 이 컴퓨터에 그 인증서가 없으면(배포용 다른 컴퓨터) 조용히 아무것도
/// 안 하고 ad-hoc 그대로 둔다.
protocol BundleSigning: Sendable {
    func resignWithLocalIdentityIfAvailable(bundleAt url: URL) throws
}

/// 릴리스 zip을 받아 검증하고 앱 번들을 교체한다(스펙 §5.1).
/// 화면을 모른다 — 진행 상황은 콜백으로만 알린다.
actor UpdateInstaller {
    private let fetcher: UpdateFetching
    private let verifier: BundleVerifying
    private let signer: BundleSigning

    init(fetcher: UpdateFetching = URLSessionFetcher(),
         verifier: BundleVerifying = CodesignVerifier(),
         signer: BundleSigning = LocalIdentityResigner()) {
        self.fetcher = fetcher
        self.verifier = verifier
        self.signer = signer
    }

    func install(
        tag: String,
        expectedVersion: String,
        targetBundle: URL,
        onProgress: @Sendable @escaping (UpdateProgress) -> Void
    ) async throws {
        let parent = targetBundle.deletingLastPathComponent()

        // 1) 사전 점검 — 쓸 수 없으면 내려받기 전에 멈춘다.
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.noWritePermission(path: parent.path)
        }

        // 교체 대상과 같은 볼륨에 작업 폴더를 둔다(다른 볼륨이면 move가 복사로 떨어진다).
        let work = parent.appendingPathComponent(".cmdALL-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 2) 다운로드
        onProgress(.downloading(fraction: 0))
        let downloaded: URL
        do {
            downloaded = try await fetcher.downloadFile(from: UpdateAssets.assetURL(tag: tag)) {
                onProgress(.downloading(fraction: $0))
            }
        } catch {
            throw UpdateInstallError.downloadFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        // 3) 체크섬 검증
        onProgress(.verifying)
        let sumsText: String
        do {
            sumsText = String(decoding: try await fetcher.data(from: UpdateAssets.sumsURL(tag: tag)),
                              as: UTF8.self)
        } catch {
            throw UpdateInstallError.downloadFailed(error.localizedDescription)
        }
        let actual = try Self.sha256Hex(of: downloaded)
        let expected = UpdateAssets.expectedHash(fromSums: sumsText, assetName: UpdateAssets.assetName)
        guard let expected, expected == actual else {
            throw UpdateInstallError.checksumMismatch(expected: expected ?? "(없음)", actual: actual)
        }

        // 4) 압축 해제
        let unpacked = work.appendingPathComponent("unpacked")
        try Self.run("/usr/bin/ditto", ["-x", "-k", downloaded.path, unpacked.path],
                     failure: { UpdateInstallError.unpackFailed($0) })
        let staged = unpacked.appendingPathComponent("cmdALL.app")
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw UpdateInstallError.unpackFailed("zip 안에서 cmdALL.app을 찾지 못했습니다")
        }

        // 5) 번들 검증(서명·버전)
        try verifier.verify(bundleAt: staged, expectedVersion: expectedVersion)

        // 5.5) 이 컴퓨터 전용 고정 인증서가 있으면 재서명(§BundleSigning 참고) —
        // ad-hoc 그대로 설치하면 CDHash가 바뀌어 "손쉬운 사용" 권한이 재발한다.
        // 재서명은 보안 통제가 아니라 편의 최적화다(보안 검증은 위 verify()가 이미
        // 담당) — 그래서 재서명 자체가 실패해도(키체인 잠김 등) 업데이트를 막지 않는다.
        // 다만 재서명을 시도한 뒤에는 반드시 다시 검증해, 서명이 섞인 채로 남은 번들이
        // 그대로 설치되는 사고("재서명 성공"이 아니라 "여전히 유효한 서명"을 확인)를 막는다.
        try? signer.resignWithLocalIdentityIfAvailable(bundleAt: staged)
        try verifier.verify(bundleAt: staged, expectedVersion: expectedVersion)

        // 6) 교체
        onProgress(.installing)
        try BundleReplacer.replace(staged: staged, target: targetBundle)
    }

    // MARK: - 도우미

    /// 큰 파일도 메모리에 통째로 올리지 않도록 조각내어 해시한다.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 외부 도구 실행. 실패하면 stderr를 실어 지정된 오류로 던진다.
    /// 로그인 키체인이 잠겨 있으면 codesign이 잠금 해제 패널을 띄우고 무한정 응답을
    /// 기다릴 수 있다(패널이 다른 창 뒤에 있으면 사용자 눈엔 "업데이트가 멈췄다"로만
    /// 보인다 — claude CLI 120초·위키 병합 300초 상한과 같은 부류 문제) — 그래서
    /// 기본 30초 상한을 두고, 초과하면 강제 종료해 실패로 처리한다.
    static func run(_ launchPath: String, _ arguments: [String],
                    timeout: TimeInterval = 30,
                    failure: (String) -> UpdateInstallError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw failure(error.localizedDescription)
        }

        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(text.isEmpty ? "종료 코드 \(process.terminationStatus)(시간 초과 포함 가능)" : text)
        }
    }
}

// MARK: - 실제 구현체

struct URLSessionFetcher: UpdateFetching {
    /// `URLSession.download(for:)`는 진행 상황을 주지 않아 0%에서 바로 완료로 튄다.
    /// 실제 진행률을 보여주려고 다운로드 델리게이트를 직접 붙인다.
    func downloadFile(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmdALL-update-\(UUID().uuidString).zip")
        let delegate = DownloadProgressDelegate(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await delegate.run(session: session, request: request)
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateInstallError.downloadFailed("HTTP \(http.statusCode)")
        }
        return data
    }
}

/// 다운로드 진행률을 보고하고, 완료 파일을 지정 위치로 옮긴다.
/// `didFinishDownloadingTo`가 준 임시 파일은 그 메서드가 반환하는 즉시 사라지므로
/// **델리게이트 안에서 동기적으로** 옮겨야 한다.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(session: URLSession, request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    /// 성공·실패를 정확히 한 번만 넘긴다(완료와 오류 콜백이 겹칠 수 있다).
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        onProgress(min(1.0, Double(written) / Double(expected)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateInstallError.downloadFailed("HTTP \(http.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onProgress(1.0)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 성공 경로는 이미 finish로 소모됐다 — 남아 있으면 실패다.
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(UpdateInstallError.downloadFailed("응답을 받지 못했습니다")))
        }
    }
}

struct CodesignVerifier: BundleVerifying {
    func verify(bundleAt url: URL, expectedVersion: String) throws {
        // 버전이 기대와 다르면(릴리스가 교체됐다든지) 설치하지 않는다.
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            throw UpdateInstallError.bundleVerificationFailed("Info.plist를 읽지 못했습니다")
        }
        guard version == expectedVersion else {
            throw UpdateInstallError.bundleVerificationFailed("버전 불일치: \(version) ≠ \(expectedVersion)")
        }
        try UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path],
                                failure: { UpdateInstallError.bundleVerificationFailed($0) })
    }
}
/// `security find-identity`·`codesign`을 직접 호출해 이 컴퓨터에 로컬 고정 인증서가
/// 있는지 확인하고, 있으면 그걸로 재서명한다. `scripts/package_app.sh`(로컬 빌드 경로)의
/// 같은 로직·같은 인증서 이름을 쓴다 — 둘 다 갱신되면 CDHash가 안정된다.
struct LocalIdentityResigner: BundleSigning {
    static let identityName = "cmdALL Local Dev"

    func resignWithLocalIdentityIfAvailable(bundleAt url: URL) throws {
        guard hasLocalIdentity() else { return }
        try UpdateInstaller.run(
            "/usr/bin/codesign",
            ["--force", "--deep", "--sign", Self.identityName, url.path],
            failure: { UpdateInstallError.bundleVerificationFailed("로컬 인증서 재서명 실패: \($0)") }
        )
    }

    private func hasLocalIdentity() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        return String(decoding: data, as: UTF8.self).contains(Self.identityName)
    }
}
