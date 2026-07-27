import Foundation
import Vision
import PDFKit
import AppKit

/// macOS 내장 Vision 프레임워크로 스캔 PDF(글자 레이어 없는 이미지 PDF)에서 텍스트를
/// 뽑는다(Docufinder 격차 6번 — OCR). 새 패키지 의존성 0.
///
/// 기본은 설정에서 꺼져 있다(`AppSettings.ocrScannedPDFsEnabled`) — 사진 한 장 OCR이
/// 일반 글자 추출보다 훨씬 느려, 대량 폴더를 훑는 배경 색인 작업을 크게 늦출 수 있어서다.
/// 텍스트 레이어가 있는 보통 PDF는 이 서비스를 아예 타지 않는다(`ContentExtractor`가
/// 먼저 시도해 성공하면 여기로 안 온다) — OCR은 정말 텍스트가 없는 스캔본일 때만의 폴백.
enum OCRService {
    /// Vision `VNImageRequestHandler.perform`은 동기(블로킹) API라 async 래핑이 필요 없다.
    /// 실패해도 nil만 반환(크래시·예외 전파 없음).
    static func recognizeText(in cgImage: CGImage, languages: [String] = ["ko-KR", "en-US"]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let results = request.results else { return nil }
        let lines = results.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// PDF 페이지 하나를 이미지로 렌더(작은 글자 인식을 위해 2배 스케일)해 OCR.
    static func recognizeText(in pdfPage: PDFPage, languages: [String] = ["ko-KR", "en-US"]) -> String? {
        let bounds = pdfPage.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let nsImage = pdfPage.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return recognizeText(in: nsImage, languages: languages)
    }

    /// 문서 전체 — 색인 목적엔 앞 `maxPages`장이면 충분하고(전체 OCR은 대용량 스캔집에서
    /// 너무 느리다), 검색은 어차피 앞부분 핵심 내용으로도 대개 걸린다.
    static func recognizeText(in document: PDFDocument, maxPages: Int = 30,
                              languages: [String] = ["ko-KR", "en-US"]) -> String? {
        var parts: [String] = []
        let pageCount = min(document.pageCount, maxPages)
        for i in 0..<pageCount {
            guard let page = document.page(at: i),
                  let text = recognizeText(in: page, languages: languages) else { continue }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
