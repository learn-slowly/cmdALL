import XCTest
@testable import CmdMD

/// 듀얼 페인 칸 하나의 순수 상태 전이(설계 §3.1).
final class BrowsePaneTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/dual-pane-root")
    let sub = URL(fileURLWithPath: "/tmp/dual-pane-root/sub")
    let file = URL(fileURLWithPath: "/tmp/dual-pane-root/sub/파일.md")

    func test초기화하면selectedFolder는rootFolder와같다() {
        let pane = BrowsePane(rootFolder: root)
        XCTAssertEqual(pane.selectedFolder, root)
        XCTAssertNil(pane.peekFile)
    }

    func testOpen은selectedFolder만바꾸고rootFolder는그대로다() {
        var pane = BrowsePane(rootFolder: root)
        pane.open(folder: sub)
        XCTAssertEqual(pane.selectedFolder, sub)
        XCTAssertEqual(pane.rootFolder, root)
    }

    func testPeek은peekFile을설정한다() {
        var pane = BrowsePane(rootFolder: root)
        pane.peek(file)
        XCTAssertEqual(pane.peekFile, file)
    }

    func testClearPeek은peekFile을비운다() {
        var pane = BrowsePane(rootFolder: root)
        pane.peek(file)
        pane.clearPeek()
        XCTAssertNil(pane.peekFile)
    }

    func testOpen은peekFile을건드리지않는다() {
        var pane = BrowsePane(rootFolder: root)
        pane.peek(file)
        pane.open(folder: sub)
        XCTAssertEqual(pane.peekFile, file, "폴더 이동과 미리보기는 독립적으로 제어돼야 한다")
    }

    func test기본레이아웃과정렬은기존기본값을따른다() {
        let pane = BrowsePane(rootFolder: root)
        XCTAssertEqual(pane.layout, .list)
        XCTAssertEqual(pane.sort.key, .para)
        XCTAssertTrue(pane.sort.ascending)
    }
}
