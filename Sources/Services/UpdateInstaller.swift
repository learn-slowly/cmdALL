import Foundation
import CryptoKit

/// 네트워크 경계 — 테스트에서 가짜로 갈아끼운다.
protocol UpdateFetching: Sendable {
    func downloadFile(from url: URL, onProgress: @Sendable (Double) -> Void) async throws -> URL
    func data(from url: URL) async throws -> Data
}

/// 번들 검증 경계(서명·버전) — 테스트에서 가짜로 갈아끼운다.
protocol BundleVerifying: Sendable {
    func verify(bundleAt url: URL, expectedVersion: String) throws
}

/// 릴리스 zip을 받아 검증하고 앱 번들을 교체한다(스펙 §5.1).
/// 화면을 모른다 — 진행 상황은 콜백으로만 알린다.
actor UpdateInstaller {
    private let fetcher: UpdateFetching
    private let verifier: BundleVerifying

    init(fetcher: UpdateFetching = URLSessionFetcher(),
         verifier: BundleVerifying = CodesignVerifier()) {
        self.fetcher = fetcher
        self.verifier = verifier
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
    static func run(_ launchPath: String, _ arguments: [String],
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
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(text.isEmpty ? "종료 코드 \(process.terminationStatus)" : text)
        }
    }
}

// MARK: - 실제 구현체

struct URLSessionFetcher: UpdateFetching {
    func downloadFile(from url: URL, onProgress: @Sendable (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateInstallError.downloadFailed("HTTP \(http.statusCode)")
        }
        // URLSession이 지우기 전에 우리 임시 위치로 옮긴다.
        let kept = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmdALL-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temp, to: kept)
        onProgress(1.0)
        return kept
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
