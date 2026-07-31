import XCTest
@testable import CmdMD

final class AppIndexSearchTests: XCTestCase {
    func testNormalizedDropsDuplicate() {
        let out = AppState.normalizedIndexFolders(["/a", "/b"], adding: "/a")
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testNormalizedDropsChildOfExisting() {
        // 이미 /a가 등록돼 있으면 그 하위 /a/sub는 추가하지 않는다(중복 인덱싱 방지).
        let out = AppState.normalizedIndexFolders(["/a"], adding: "/a/sub")
        XCTAssertEqual(out, ["/a"])
    }

    func testNormalizedReplacesParentWhenAddingAncestor() {
        // 새로 추가하는 /a가 기존 /a/sub의 상위면, 하위를 흡수해 /a만 남긴다.
        let out = AppState.normalizedIndexFolders(["/a/sub", "/b"], adding: "/a")
        XCTAssertEqual(Set(out), Set(["/a", "/b"]))
    }

    func testNormalizedAppendsUnrelated() {
        let out = AppState.normalizedIndexFolders(["/a"], adding: "/b")
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testNormalizedPreservesPrivatePrefixedCanonicalPath() {
        // canonical 경로(/private/var/...)를 그대로 저장해야 한다. standardizingPath가 /private를 떼면 안 된다.
        let out = AppState.normalizedIndexFolders([], adding: "/private/var/folders/abc/Docs")
        XCTAssertEqual(out, ["/private/var/folders/abc/Docs"])
    }

    @MainActor
    func testIndexingStateDefaults() {
        let dir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dir) }
        let app = AppState(dataDirectory: dir)
        XCTAssertFalse(app.indexInProgress)
        XCTAssertNil(app.indexProgress)
    }


    /// 앱을 켤 때 자동으로 도는 1회성 재색인(스키마·추출판 변경 시)엔 진행 표시가
    /// 안 붙어 있었다 — reindexFolder(수동 버튼)엔 있는 진행률 콜백을 자동 경로에도
    /// 연결했는지 확인한다.
    @MainActor
    func testAutoSchemaMigrationReindexShowsProgress() async throws {
        let dataDir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dataDir) }
        let folder = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(folder) }
        for i in 0..<10 {
            try "내용 \(i)".write(to: folder.appendingPathComponent("파일\(i).md"),
                                  atomically: true, encoding: .utf8)
        }

        let app = AppState(dataDirectory: dataDir)
        // AppState.init이 예약만 해둔 자동 재훑기 Task가 아직 안 돌았을 때(첫 await 전)
        // 등록 폴더를 미리 심어둔다 — §AutoContentIndexingTests와 동일한 순서 보장 패턴.
        app.settings.indexedFolders = [SearchIndexer.canonicalURL(folder).path]

        var sawProgress = false
        for _ in 0..<300 {
            if app.indexInProgress { sawProgress = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        for _ in 0..<300 where app.indexInProgress {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(sawProgress, "앱을 켤 때 자동으로 도는 1회성 재색인 중에도 진행 표시가 떠야 한다")
        XCTAssertFalse(app.indexInProgress)
        XCTAssertNil(app.indexProgress)
    }
}
