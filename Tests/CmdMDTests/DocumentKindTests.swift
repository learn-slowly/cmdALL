import XCTest
@testable import CmdMD

final class DocumentKindTests: XCTestCase {
    private func kind(_ name: String) -> DocumentKind {
        DocumentKind(from: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testImageExtensionsMapToImage() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp", "gif"] {
            XCTAssertEqual(kind("file.\(ext)"), .image, "\(ext) should be image")
        }
    }

    func testUppercaseAndMixedCaseMapToImage() {
        XCTAssertEqual(kind("PHOTO.PNG"), .image)
        XCTAssertEqual(kind("Pic.Jpg"), .image)
    }

    func testMarkdownAndTextMapToMarkdown() {
        for ext in ["md", "markdown", "txt"] {
            XCTAssertEqual(kind("note.\(ext)"), .markdown, "\(ext) should be markdown")
        }
    }

    func testUnknownAndNoExtensionFallBackToQuickLook() {
        // 조각 A(QuickLook fallback) 도입 이후: 모르는 형식·확장자 없음은
        // 더 이상 markdown으로 새지 않고 quickLook(애플 미리보기)으로 간다.
        XCTAssertEqual(kind("data.xyz"), .quickLook)
        XCTAssertEqual(kind("README"), .quickLook)
    }

    func testImageExtensionsSetMatchesMapping() {
        for ext in DocumentKind.imageExtensions {
            XCTAssertEqual(kind("a.\(ext)"), .image)
        }
    }

    func testPdfMapsToPdf() {
        XCTAssertEqual(kind("doc.pdf"), .pdf)
        XCTAssertEqual(kind("REPORT.PDF"), .pdf)
        XCTAssertEqual(kind("Paper.Pdf"), .pdf)
    }

    func testPdfExtensionsSetMatchesMapping() {
        for ext in DocumentKind.pdfExtensions {
            XCTAssertEqual(kind("a.\(ext)"), .pdf)
        }
    }

    func testOfficeExtensionsMapToOffice() {
        for ext in ["hwp", "hwpx", "hwpml", "doc", "docx", "xls", "xlsx"] {
            XCTAssertEqual(kind("file.\(ext)"), .office, "\(ext) should be office")
        }
    }

    func testOfficeUppercaseMapsToOffice() {
        XCTAssertEqual(kind("문서.HWP"), .office)
        XCTAssertEqual(kind("Sheet.XLSX"), .office)
    }

    func testPdfStillPdfAndImageUnchanged() {
        XCTAssertEqual(kind("a.pdf"), .pdf)
        XCTAssertEqual(kind("a.png"), .image)
        XCTAssertEqual(kind("a.md"), .markdown)
    }

    // MARK: - Docufinder 격차 5번(원본 그대로 보기)

    func testNativelyRenderableOfficeExtensionsAcceptsMSOfficeOnly() {
        for ext in ["doc", "docx", "xls", "xlsx"] {
            XCTAssertTrue(DocumentKind.nativelyRenderableOfficeExtensions.contains(ext))
        }
    }

    func testNativelyRenderableOfficeExtensionsExcludesHWPFamily() {
        for ext in ["hwp", "hwpx", "hwpml"] {
            XCTAssertFalse(DocumentKind.nativelyRenderableOfficeExtensions.contains(ext),
                            "\(ext)은 macOS QuickLook이 못 읽어 원본 보기 대상이 아니어야 한다")
        }
    }

    func testHwpConvertRenderableExtensionsIsHWPOnly() {
        XCTAssertTrue(DocumentKind.hwpConvertRenderableExtensions.contains("hwp"))
        for ext in ["hwpx", "hwpml", "doc", "docx", "xls", "xlsx"] {
            XCTAssertFalse(DocumentKind.hwpConvertRenderableExtensions.contains(ext),
                            "hwp-convert 원본 보기는 구형 hwp 전용이어야 한다(\(ext) 제외)")
        }
    }
}
