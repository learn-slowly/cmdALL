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

    func testLoadCGImageReadsRealPNGFile() throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let image = imageWithText("HI", size: CGSize(width: 200, height: 100))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return XCTFail("PNG 인코딩 실패") }
        let url = dir.appendingPathComponent("photo.png")
        try png.write(to: url)

        let cgImage = OCRService.loadCGImage(from: url)

        XCTAssertNotNil(cgImage)
        XCTAssertGreaterThan(cgImage?.width ?? 0, 0, "디코딩된 이미지 폭이 있어야 한다(화면 배율에 따라 200 또는 400)")
    }

    func testLoadCGImageReturnsNilForMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/cmdall-없는-사진-\(UUID().uuidString).png")

        XCTAssertNil(OCRService.loadCGImage(from: missing))
    }

    func testLoadCGImageReturnsNilForCorruptData() throws {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let url = dir.appendingPathComponent("깨진.png")
        try Data([0x00, 0x01, 0x02]).write(to: url)

        XCTAssertNil(OCRService.loadCGImage(from: url))
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

    func testOcrImagesEnabledDefaultsOff() {
        // 사진 OCR도 스캔 PDF OCR과 같은 이유로 기본은 꺼져 있어야 한다.
        XCTAssertFalse(AppSettings().ocrImagesEnabled)
    }

    func testOcrImagesEnabledIsIndependentOfScannedPDFsToggle() {
        var settings = AppSettings()
        settings.ocrImagesEnabled = true

        XCTAssertTrue(settings.ocrImagesEnabled)
        XCTAssertFalse(settings.ocrScannedPDFsEnabled, "사진 OCR을 켜도 스캔 PDF OCR은 별개로 꺼져 있어야 한다")
    }
}
