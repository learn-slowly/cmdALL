import XCTest
@testable import CmdMD

final class FileTreeListingTests: XCTestCase {
    private func listable(_ name: String) -> Bool {
        AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testMarkdownAndTextAreListed() {
        for ext in ["md", "markdown", "txt"] {
            XCTAssertTrue(listable("note.\(ext)"), "\(ext) should be listed")
        }
    }

    func testImagesAreListed() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp", "gif"] {
            XCTAssertTrue(listable("pic.\(ext)"), "\(ext) should be listed")
        }
    }

    func testUppercaseImagesAreListed() {
        XCTAssertTrue(listable("PHOTO.PNG"))
        XCTAssertTrue(listable("Clip.GIF"))
    }

    func testPdfIsListed() {
        XCTAssertTrue(listable("paper.pdf"))
        XCTAssertTrue(listable("REPORT.PDF"))
    }

    func testOfficeFilesAreListed() {
        for ext in ["hwp", "hwpx", "docx", "xlsx"] {
            XCTAssertTrue(listable("doc.\(ext)"), "\(ext) should be listed")
        }
    }

    func test모르는형식도이제목록에보인다() {
        // 조각 A(QuickLook fallback) 도입 이후: 모르는 형식은 제외가 아니라
        // DocumentKind.quickLook(애플 미리보기)으로 열리도록 목록에 그대로 보인다.
        for ext in ["zip", "avi", "exe"] {
            XCTAssertTrue(listable("doc.\(ext)"), "\(ext)도 목록에 보여야 한다")
        }
    }
}
