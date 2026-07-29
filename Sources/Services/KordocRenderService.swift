import Foundation

enum KordocRenderError: Error {
    case toolNotFound
    case timeout
    case renderFailed(String)
}

/// kordoc `render`(SVG)를 Process로 호출해 `.hwpx` 원본 조판을 그린다. kordoc 자체는 구현하지
/// 않는다(외부 도구). **`.hwpx` 전용** — kordoc에 `.hwp`(구버전 바이너리) 렌더 기능은 없다
/// (실측 확인, 2026-07-29, `docs/superpowers/specs/2026-07-29-hwpx-native-render-design.md` §3).
/// 조판 캐시가 없는 파일(kordoc 자체 생성/편집본)은 렌더가 실패하는데, `--reflow` 자동 폴백은
/// 이번 범위 밖이라 그대로 실패로 throw한다(설계 문서 §4-2).
actor KordocRenderService {
    private let timeout: TimeInterval = 120
    /// 렌더 HTML 세션 캐시(키=경로, 값=수정시각+HTML). 같은 파일 재요청 시 재렌더 방지.
    private var svgCache: [String: (mtime: Date, html: String)] = [:]

    func renderHTML(for fileURL: URL) async throws -> String {
        let key = fileURL.path(percentEncoded: false)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        if let mtime, let hit = svgCache[key], hit.mtime == mtime {
            return hit.html
        }

        guard let npx = KordocService.resolveNpxPath() else { throw KordocRenderError.toolNotFound }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("svg")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", KordocService.packageSpec, "render",
                             fileURL.path(percentEncoded: false),
                             "-o", tmp.path(percentEncoded: false), "--silent"]
        process.environment = SubprocessEnvironment.environment(forTool: npx)
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw KordocRenderError.toolNotFound
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocRenderError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw KordocRenderError.renderFailed(String(msg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
        }

        guard let svg = try? String(contentsOf: tmp, encoding: .utf8) else {
            throw KordocRenderError.renderFailed("출력 파일을 읽지 못했습니다.")
        }
        let html = Self.wrapSVG(svg)
        if let mtime {
            svgCache[key] = (mtime, html)
        }
        return html
    }

    /// SVG 문자열을 WKWebView에 바로 로드할 수 있는 최소 HTML로 감싼다(순수 함수).
    /// 입력이 SVG가 아니어도 파싱·검증 없이 그대로 본문에 실어 반환한다 — 크래시 없음.
    static func wrapSVG(_ svg: String) -> String {
        """
        <html>
        <head><meta charset="utf-8"></head>
        <body style="margin:0;background:#ffffff;">
        \(svg)
        </body>
        </html>
        """
    }
}
