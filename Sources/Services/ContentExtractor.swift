import Foundation
import PDFKit

/// 파일 URL → 인덱싱 본문. 없으면 nil(파일명만 인덱싱).
/// office는 kordoc(Process) 비동기 추출, 그 외(글자/pdf/이미지)는 동기 로컬 추출.
enum ContentExtractor {

    /// 본문으로 읽을 최대 크기. 큰 기록 파일이 통째로 메모리·색인에 들어가는 것을 막는다.
    /// 넘으면 nil → 파일 이름만 색인(스펙 §3.6).
    static let maxTextBytes = 5 * 1024 * 1024

    /// 사진 한 장을 OCR로 읽을 최대 크기. 텍스트 파일보다 사진이 원래 훨씬 커서
    /// `maxTextBytes`(5MB)를 그대로 쓰면 대부분 걸러진다 — 별도로 20MB.
    static let maxOCRImageBytes = 20 * 1024 * 1024

    /// kordoc 없이 즉시 추출 가능한 종류(글자/pdf/이미지)만. 미지원·없는 파일은 nil.
    /// `ocrScannedPDFs`가 켜져 있고 PDF에 글자 레이어가 전혀 없으면(스캔본) Vision OCR로
    /// 폴백한다(Docufinder 격차 6번 — 기본 OFF, 설정에서 켠다).
    /// `ocrImages`가 켜져 있으면 이미지 파일(png·jpg·heic·webp·gif)도 Vision OCR로 읽는다
    /// (Docufinder 격차 3번 — 기본 OFF, 20MB 넘는 사진은 이름만 색인).
    static func localBody(for url: URL, ocrScannedPDFs: Bool = false, ocrImages: Bool = false) -> String? {
        let ext = url.pathExtension.lowercased()

        if DocumentKind.imageExtensions.contains(ext) {
            guard ocrImages else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxOCRImageBytes else { return nil }
            guard let cgImage = OCRService.loadCGImage(from: url) else { return nil }
            return OCRService.recognizeText(in: cgImage)
        }

        if DocumentKind.pdfExtensions.contains(ext) {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var parts: [String] = []
            for i in 0..<pdf.pageCount {
                if let s = pdf.page(at: i)?.string,
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(s)
                }
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
            guard ocrScannedPDFs else { return nil }
            return OCRService.recognizeText(in: pdf)
        }

        // 이메일(.eml)은 여는 방식(QuickLook — Mail 미리보기가 더 나음, Phase 12 유지)과
        // 색인 방식을 일부러 분리한다 — 원문 그대로 색인하면 헤더 인코딩·첨부 base64가
        // 그대로 섞여 검색이 오염되니 EmailExtractor로 제목/보낸사람/받는사람/본문만 뽑는다
        // (Docufinder 격차 7번).
        if ext == "eml" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxTextBytes else { return nil }
            let raw = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            guard let raw else { return nil }
            let text = EmailExtractor.searchableText(rawEML: raw)
            return text.isEmpty ? nil : text
        }

        // 글자 파일 판정은 QuickLookRouting 하나만 쓴다 — 여는 규칙과 색인 규칙이
        // 어긋나지 않게(스펙 §3.6).
        guard QuickLookRouting.opensAsText(extension: ext) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxTextBytes else { return nil }

        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 종류별 본문. office면 kordoc 분기, 그 외는 localBody.
    static func body(for url: URL, kordoc: KordocService, ocrScannedPDFs: Bool = false, ocrImages: Bool = false) async -> String? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.officeExtensions.contains(ext) {
            return try? await kordoc.markdown(for: url)
        }
        return localBody(for: url, ocrScannedPDFs: ocrScannedPDFs, ocrImages: ocrImages)
    }
}
