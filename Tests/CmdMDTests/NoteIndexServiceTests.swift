import XCTest
@testable import CmdMD

final class NoteIndexServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteIndexServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeNotes(_ count: Int) throws {
        for i in 0..<count {
            let url = tempDir.appendingPathComponent("note-\(i).md")
            try "note \(i)".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func testBuildIndexFindsAllNotesUnderNewHighLimit() throws {
        try makeNotes(20)
        let notes = NoteIndexService.buildIndex(roots: [tempDir])
        XCTAssertEqual(notes.count, 20)
    }

    func testBuildIndexStopsAtExplicitLimit() throws {
        try makeNotes(25)
        let notes = NoteIndexService.buildIndex(roots: [tempDir], limit: 10)
        XCTAssertEqual(notes.count, 10, "커스텀 상한을 넘기면 그 자리에서 멈춰야 한다")
    }

    func testBuildIndexReportsProgressInChunks() throws {
        try makeNotes(25)
        var chunkCounts: [Int] = []
        let notes = NoteIndexService.buildIndex(roots: [tempDir], chunkSize: 10) { chunk in
            chunkCounts.append(chunk.count)
        }
        XCTAssertEqual(notes.count, 25)
        XCTAssertEqual(chunkCounts, [10, 20], "10개씩 모일 때마다 중간 진행을 알려야 한다(마지막 5개는 최종 반환값에만 포함)")
    }

    func testBuildIndexWithoutOnChunkStillReturnsEverything() throws {
        try makeNotes(5)
        let notes = NoteIndexService.buildIndex(roots: [tempDir])
        XCTAssertEqual(Set(notes.map(\.title)), Set((0..<5).map { "note-\($0)" }))
    }
}
