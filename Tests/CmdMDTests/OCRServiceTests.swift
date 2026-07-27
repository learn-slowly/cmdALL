import XCTest
import PDFKit
import AppKit
@testable import CmdMD

final class OCRServiceTests: XCTestCase {

    private func blankImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func imageWithText(_ text: String, size: CGSize) -> NSImage {
        let image = blankImage(size: size)
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: text).draw(at: NSPoint(x: 20, y: size.height / 2 - 40), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    func testRecognizeTextReturnsNilForBlankImage() throws {
        let image = blankImage(size: CGSize(width: 200, height: 100))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        let text = OCRService.recognizeText(in: cgImage)

        XCTAssertNil(text)
    }

    func testRecognizeTextFindsRenderedWord() throws {
        let image = imageWithText("HELLO", size: CGSize(width: 400, height: 200))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        let text = OCRService.recognizeText(in: cgImage, languages: ["en-US"])

        XCTAssertNotNil(text)
        XCTAssertTrue(text?.uppercased().contains("HELLO") ?? false, "인식 결과: \(text ?? "nil")")
    }

    func testLocalBodySkipsOCRWhenDisabledForTextlessPDF() throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let image = blankImage(size: CGSize(width: 200, height: 100))
        let pdfDoc = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        pdfDoc.insert(page, at: 0)
        let url = dir.appendingPathComponent("scan.pdf")
        XCTAssertTrue(pdfDoc.write(to: url))

        let body = ContentExtractor.localBody(for: url, ocrScannedPDFs: false)

        XCTAssertNil(body, "OCR이 꺼져 있으면 글자 레이어 없는(스캔) PDF는 본문 없이 색인돼야 한다")
    }

    func testLocalBodyUsesOCRWhenEnabledForTextlessPDF() throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let image = imageWithText("SCAN", size: CGSize(width: 400, height: 200))
        let pdfDoc = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        pdfDoc.insert(page, at: 0)
        let url = dir.appendingPathComponent("scan2.pdf")
        XCTAssertTrue(pdfDoc.write(to: url))

        let body = ContentExtractor.localBody(for: url, ocrScannedPDFs: true)

        XCTAssertNotNil(body)
        XCTAssertTrue(body?.uppercased().contains("SCAN") ?? false, "OCR 결과: \(body ?? "nil")")
    }

    func testOcrScannedPDFsEnabledDefaultsOff() {
        // 사진 한 장 OCR이 일반 글자 추출보다 훨씬 느려, 대량 폴더 훑기를 늦출 위험이
        // 있으므로 기본은 반드시 꺼져 있어야 한다.
        XCTAssertFalse(AppSettings().ocrScannedPDFsEnabled)
    }
}
