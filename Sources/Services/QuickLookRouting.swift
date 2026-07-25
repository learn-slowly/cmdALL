import Foundation
import UniformTypeIdentifiers

/// 확장자 → "편집기로 글처럼 열까 / 애플 미리보기로 넘길까" 판정.
/// DocumentKind·목록 필터·검색 색인이 모두 이 하나를 재사용한다(단일 진실 원천).
enum QuickLookRouting {

    /// 맥에 묻지 않고 바로 "글자"로 판정하는 빠른 경로.
    /// 두 몫을 한다 — (1) 목록 정렬처럼 항목마다 불리는 곳의 조회 비용 제거
    /// (2) 맥이 `dyn.…`으로 답해 '글자 아님'이 되는 흔한 설정 파일 구제(실측).
    static let textFastPath: Set<String> = [
        "md", "markdown", "mdown", "txt", "text",
        "csv", "tsv", "json", "yml", "yaml", "toml", "ini", "conf", "cfg",
        "xml", "html", "htm", "css", "js", "ts", "jsx", "tsx",
        "py", "sh", "zsh", "bash", "rb", "go", "rs", "java", "kt",
        "swift", "c", "h", "cpp", "hpp", "m", "mm",
        "log", "srt", "vtt", "tex", "bib", "env", "gitignore", "mdx"
    ]

    /// 맥이 "글자"라 답해도 편집기로 열지 않을 예외.
    /// rtf/rtfd는 public.rtf(텍스트 계열)지만 편집기에는 서식 부호가 그대로 보인다.
    static let textExceptions: Set<String> = ["rtf", "rtfd"]

    /// 맥에 물어본 결과 캐시 — 백그라운드 트리 스캔에서도 불리므로 잠금으로 보호한다.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    /// true = 편집기로 연다(기존 동작). false = 애플 미리보기로 넘긴다.
    static func opensAsText(extension ext: String) -> Bool {
        let key = ext.lowercased()
        if key.isEmpty { return false }
        if textExceptions.contains(key) { return false }
        if textFastPath.contains(key) { return true }

        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let answer = UTType(filenameExtension: key)?.conforms(to: .text) ?? false

        cacheLock.lock()
        cache[key] = answer
        cacheLock.unlock()
        return answer
    }

    /// URL 편의 오버로드.
    static func opensAsText(_ url: URL) -> Bool {
        opensAsText(extension: url.pathExtension)
    }
}
