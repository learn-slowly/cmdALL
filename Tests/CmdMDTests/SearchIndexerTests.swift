import XCTest
@testable import CmdMD

final class SearchIndexerTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-idxr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-idxr-\(UUID().uuidString).sqlite")
    }

    func testIndexFolderIndexesTextFilesAndSearches() async throws {
        let dir = tempDir()
        try "사과 바나나".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "포도 수박".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        // XCTAssertEqual은 autoclosure라 await를 직접 받지 못하므로 미리 추출.
        let count = await index.count()
        XCTAssertEqual(count, 2)
        let hits = await index.search(query: "바나나")
        // enumerator는 정규 경로(/private/var/...)를 반환하므로 기대값도 맞춰 준다.
        let expectedPath = (try? dir.appendingPathComponent("a.md")
            .resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            ?? dir.appendingPathComponent("a.md").path
        XCTAssertEqual(hits.first?.path, expectedPath)
    }

    func testIndexFolderRemovesDeletedFiles() async throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.md")
        try "사과".write(to: a, atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        let count1 = await index.count()
        XCTAssertEqual(count1, 1)
        try FileManager.default.removeItem(at: a)        // 파일 삭제
        await indexer.indexFolder(dir, progress: nil)    // 재인덱싱 → 사라진 파일 제거
        let count2 = await index.count()
        XCTAssertEqual(count2, 0)
    }

    func testReindexSingleFileAndDeletion() async throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.md")
        try "사과".write(to: a, atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.reindex(path: a.path)
        let count1 = await index.count()
        XCTAssertEqual(count1, 1)
        try FileManager.default.removeItem(at: a)
        await indexer.reindex(path: a.path)              // 삭제된 파일 → remove
        let count2 = await index.count()
        XCTAssertEqual(count2, 0)
    }

    func test하위폴더자신은문서로색인되지않는다() async throws {
        // 조각 A(QuickLook fallback)로 isListableInFileTree가 확장자 무관 항상 true가
        // 되면서(회귀), 폴더 자신도 색인 대상으로 새는 결함이 있었다 — 실제 파일만
        // 색인해야 한다.
        let dir = tempDir()
        let sub = dir.appendingPathComponent("하위폴더")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "내용".write(to: sub.appendingPathComponent("메모.md"), atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        let count = await index.count()
        XCTAssertEqual(count, 1, "하위 폴더 자신은 빼고 그 안의 파일 1개만 색인돼야 한다")
    }

    /// 2026-07-28 실사용 발견 — 홈 폴더처럼 큰 폴더를 고르면 개발 도구 부속 폴더
    /// (venv·node_modules 등)와 숨김 폴더가 실제 문서보다 먼저 훑여 며칠이 지나도
    /// 정작 필요한 폴더에 색인이 못 닿았다. 이런 폴더는 통째로 건너뛰어야 한다.
    func test개발도구부속폴더와숨김폴더는건너뛴다() async throws {
        let dir = tempDir()
        try "진짜 노트".write(to: dir.appendingPathComponent("메모.md"), atomically: true, encoding: .utf8)

        let venv = dir.appendingPathComponent("venv")
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        try "가짜".write(to: venv.appendingPathComponent("부스러기.md"), atomically: true, encoding: .utf8)

        let nodeModules = dir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "가짜".write(to: nodeModules.appendingPathComponent("부스러기.md"), atomically: true, encoding: .utf8)

        let hiddenGit = dir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: hiddenGit, withIntermediateDirectories: true)
        try "가짜".write(to: hiddenGit.appendingPathComponent("부스러기.md"), atomically: true, encoding: .utf8)

        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        let count = await index.count()
        XCTAssertEqual(count, 1, "venv·node_modules·숨김 폴더 부스러기는 빼고 진짜 노트 1개만 색인돼야 한다")
    }

    /// 지름길(symlink)이 고른 폴더 밖을 가리키면 따라가지 않는다 — 실사용에서
    /// 홈 폴더를 고르자 /Library/Developer/... 시스템 폴더까지 새어 들어간 사례 확인.
    func test심볼릭링크가폴더밖을가리키면건너뛴다() async throws {
        let dir = tempDir()
        try "진짜 노트".write(to: dir.appendingPathComponent("메모.md"), atomically: true, encoding: .utf8)

        let outside = tempDir()
        try "밖의 파일".write(to: outside.appendingPathComponent("바깥.md"), atomically: true, encoding: .utf8)

        let link = dir.appendingPathComponent("지름길")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        let count = await index.count()
        XCTAssertEqual(count, 1, "지름길이 가리키는 폴더 밖 내용은 빼고 진짜 노트 1개만 색인돼야 한다")
    }
}
