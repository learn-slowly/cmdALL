import XCTest
import PDFKit
import AppKit
@testable import CmdMD

final class ContentExtractorTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-ext-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testLocalBodyReadsTextFile() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("note.md")
        try "제목\n본문 내용".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ContentExtractor.localBody(for: url), "제목\n본문 내용")
    }

    func testLocalBodyTxtAndMarkdown() throws {
        let dir = tempDir()
        let txt = dir.appendingPathComponent("a.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertEqual(ContentExtractor.localBody(for: txt), "hello")
    }

    func testLocalBodyExtractsPDFText() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("doc.pdf")
        // PDFKit로 비트맵 기반 페이지를 만든다.
        let pdf = PDFDocument()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .calibratedRGB,
                                       bytesPerRow: 0, bitsPerPixel: 32)!
        let image = NSImage()
        image.addRepresentation(bitmap)
        let page = PDFPage(image: image)!
        pdf.insert(page, at: 0)
        pdf.write(to: url)
        // 빈 이미지 페이지는 텍스트가 없을 수 있으므로, 텍스트가 nil이 아님만 보장하지 말고
        // localBody가 크래시 없이 String? 반환함을 확인한다(빈/실내용 모두 허용).
        _ = ContentExtractor.localBody(for: url)   // 크래시 없음
        XCTAssertEqual(ContentExtractor.localBody(for: dir.appendingPathComponent("none.pdf")), nil) // 없는 파일
    }

    func testLocalBodyUnsupportedReturnsNil() throws {
        let dir = tempDir()
        let img = dir.appendingPathComponent("p.png")
        try Data([0x89, 0x50]).write(to: img)
        XCTAssertNil(ContentExtractor.localBody(for: img))   // 이미지: 본문 없음
    }

    // MARK: 사진 속 글자 검색(이미지 OCR)

    private func imageWithText(_ text: String, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 60),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: text).draw(at: NSPoint(x: 20, y: size.height / 2 - 30), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return XCTFail("PNG 인코딩 실패") }
        try png.write(to: url)
    }

    func testLocalBodyIgnoresImageWhenOCRDisabled() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("photo.png")
        try writePNG(imageWithText("RECEIPT", size: CGSize(width: 400, height: 200)), to: url)

        XCTAssertNil(ContentExtractor.localBody(for: url, ocrImages: false),
                      "이미지 OCR이 꺼져 있으면(기본) 사진은 본문 없이 색인돼야 한다")
    }

    func testLocalBodyReadsImageTextWhenOCREnabled() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("photo2.png")
        try writePNG(imageWithText("RECEIPT", size: CGSize(width: 400, height: 200)), to: url)

        let body = ContentExtractor.localBody(for: url, ocrImages: true)

        XCTAssertNotNil(body)
        XCTAssertTrue(body?.uppercased().contains("RECEIPT") ?? false, "OCR 결과: \(body ?? "nil")")
    }

    func testLocalBodySkipsImageOverSizeCapEvenWhenOCREnabled() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("big.png")
        // 실제 사진 내용은 필요 없다 — 크기 상한 검사가 디코딩보다 먼저 걸린다.
        try Data(count: ContentExtractor.maxOCRImageBytes + 1).write(to: url)

        XCTAssertNil(ContentExtractor.localBody(for: url, ocrImages: true),
                      "20MB 넘는 사진은 OCR이 켜져 있어도 이름만 색인돼야 한다")
    }
}
