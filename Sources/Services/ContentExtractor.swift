import Foundation
import PDFKit

/// 파일 URL → 인덱싱 본문. 없으면 nil(파일명만 인덱싱).
/// office는 kordoc(Process) 비동기 추출, 그 외(글자/pdf)는 동기 로컬 추출.
enum ContentExtractor {

    /// 본문으로 읽을 최대 크기. 큰 기록 파일이 통째로 메모리·색인에 들어가는 것을 막는다.
    /// 넘으면 nil → 파일 이름만 색인(스펙 §3.6).
    static let maxTextBytes = 5 * 1024 * 1024

    /// kordoc 없이 즉시 추출 가능한 종류(글자/pdf)만. 미지원·없는 파일은 nil.
    static func localBody(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()

        if DocumentKind.pdfExtensions.contains(ext) {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var parts: [String] = []
            for i in 0..<pdf.pageCount {
                if let s = pdf.page(at: i)?.string { parts.append(s) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }

        // 글자 파일 판정은 QuickLookRouting 하나만 쓴다 — 여는 규칙과 색인 규칙이
        // 어긋나지 않게(스펙 §3.6).
        guard QuickLookRouting.opensAsText(extension: ext) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxTextBytes else { return nil }

        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 종류별 본문. office면 kordoc 분기, 그 외는 localBody.
    static func body(for url: URL, kordoc: KordocService) async -> String? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.officeExtensions.contains(ext) {
            return try? await kordoc.markdown(for: url)
        }
        return localBody(for: url)
    }
}
