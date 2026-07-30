import Foundation

enum KordocError: Error {
    case toolNotFound
    case conversionFailed(String)
    case timeout
    case decodeFailed
}

/// kordoc CLI를 Process로 호출해 한글·오피스 문서를 KordocResult로 변환한다.
/// kordoc 자체는 구현하지 않는다(외부 도구). 실패는 throw로만 — 크래시 금지.
actor KordocService {
    private let timeout: TimeInterval = 120
    /// 변환 마크다운 세션 캐시(키=경로, 값=수정시각+마크다운). 같은 파일 재검색 시 재변환 방지.
    private var markdownCache: [String: (mtime: Date, markdown: String)] = [:]

    func convert(fileURL: URL) async throws -> KordocResult {
        guard let npx = Self.resolveNpxPath() else { throw KordocError.toolNotFound }

        // 작업 폴더를 직접 통제한다 — 예전엔 CWD를 안 정해줘서(대개 앱 실행 경로,
        // 쓰기 금지인 경우가 흔함) kordoc이 사진을 images/ 하위에 뽑아내려다 조용히
        // 실패하는 문제가 있었다(실사용 보고, 2026-07-30 — hwpx 사진 미표시, 에러 없이
        // 글만 나옴). 항상 쓰기 가능한 임시 폴더를 CWD로 주면 이 문제가 해소된다.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kordoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let tmp = workDir.appendingPathComponent("result.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.currentDirectoryURL = workDir
        process.arguments = ["-y", Self.packageSpec, fileURL.path(percentEncoded: false),
                             "--format", "json", "-o", tmp.path(percentEncoded: false), "--silent"]
        process.environment = SubprocessEnvironment.environment(forTool: npx)
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice   // -o로 출력, stdout 불필요

        do {
            try process.run()
        } catch {
            throw KordocError.toolNotFound
        }

        // 타임아웃 감시(협조적 폴링; --silent라 stderr 버퍼 넘침 위험 낮음).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw KordocError.conversionFailed(String(msg.prefix(500)))
        }

        guard let data = try? Data(contentsOf: tmp) else {
            throw KordocError.conversionFailed("출력 파일이 생성되지 않았습니다.")
        }
        guard var result = try? JSONDecoder().decode(KordocResult.self, from: data) else {
            throw KordocError.decodeFailed
        }

        // kordoc이 사진을 뽑아냈으면(images/ 하위 폴더 실측 확인) 그 폴더를 미리보기
        // baseURL 후보로 알려준다 — markdown의 참조(`image_001.png`, 접두어 없음)가
        // 이 폴더를 기준으로 해야 맞는다(kordoc 자체의 참조·실위치 어긋남 우회).
        let imagesDir = workDir.appendingPathComponent("images", isDirectory: true)
        if FileManager.default.fileExists(atPath: imagesDir.path) {
            result.assetDirectory = imagesDir
        }
        // json 자체는 다 읽었으니 지워도 되지만, 이미지 폴더는 렌더가 나중에 읽어야
        // 하므로 작업 폴더 전체는 앱 세션 동안(또는 다음 재부팅 때까지) 그대로 둔다.
        try? FileManager.default.removeItem(at: tmp)

        return result
    }

    /// 변환된 마크다운만 반환(캐시 사용). 파일 수정시각이 바뀌면 재변환한다.
    func markdown(for fileURL: URL) async throws -> String {
        let key = fileURL.path(percentEncoded: false)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        if let mtime, let hit = markdownCache[key], hit.mtime == mtime {
            return hit.markdown
        }
        let result = try await convert(fileURL: fileURL)
        if let mtime {
            markdownCache[key] = (mtime, result.markdown)
        }
        return result.markdown
    }

    /// GUI 앱(.app)은 로그인 셸 PATH를 상속하지 않으므로 npx 절대경로를 탐지한다.
    /// 흔한 설치 경로 → 그래도 없으면 로그인 셸의 `which npx`.
    static func resolveNpxPath() -> String? {
        let candidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "which npx"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        } catch { }
        return nil
    }

    /// npx에 넘길 kordoc 패키지 지정자. 버전 없이 그냥 "kordoc"만 넘기면 npx가 로컬에
    /// 이미 받아둔 옛날 버전을 그대로 재사용하는 경우가 있어(실측 확인 — 몇 달 지난 버전이
    /// 계속 잡혔다), "@latest"를 명시해 매번 진짜 최신 버전을 받아쓰도록 고정한다.
    static let packageSpec = "kordoc@latest"
}
