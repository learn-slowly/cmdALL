import XCTest
@testable import CmdMD

/// "문서에서 할일 찾기 → Todoist" 전송 이력 저장소 — 왕복·최신순 정렬·상한(200건) 확인.
final class SentTaskLogStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        super.tearDown()
    }

    private func makeRecord(text: String, sentAt: Date) -> SentTaskRecord {
        SentTaskRecord(id: UUID(), text: text, sourceFileName: "메모.md",
                       sourcePath: "/tmp/메모.md", sentAt: sentAt, todoistTaskId: "t-\(text)")
    }

    func testAppendThenLoadRoundTrips() async {
        let store = SentTaskLogStore(directory: tempDir)
        let record = makeRecord(text: "할일1", sentAt: Date())
        await store.append(record)
        let loaded = await store.load()
        XCTAssertEqual(loaded, [record])
    }

    func testLoadNewestFirstOrdersByDateDescending() async {
        let store = SentTaskLogStore(directory: tempDir)
        let older = makeRecord(text: "옛날", sentAt: Date(timeIntervalSince1970: 1000))
        let newer = makeRecord(text: "최근", sentAt: Date(timeIntervalSince1970: 2000))
        await store.append(older)
        await store.append(newer)
        let loaded = await store.loadNewestFirst()
        XCTAssertEqual(loaded.map(\.text), ["최근", "옛날"])
    }

    func testPersistsAcrossInstances() async {
        let store1 = SentTaskLogStore(directory: tempDir)
        await store1.append(makeRecord(text: "영속됨", sentAt: Date()))
        let store2 = SentTaskLogStore(directory: tempDir)
        let loaded = await store2.load()
        XCTAssertEqual(loaded.map(\.text), ["영속됨"])
    }

    func testCapsAtMaxRecordsDroppingOldest() async {
        let store = SentTaskLogStore(directory: tempDir)
        for i in 0..<205 {
            await store.append(makeRecord(text: "항목\(i)", sentAt: Date(timeIntervalSince1970: Double(i))))
        }
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 200)
        XCTAssertEqual(loaded.first?.text, "항목5", "오래된 5건은 잘려나가야 한다")
        XCTAssertEqual(loaded.last?.text, "항목204")
    }

    func testEmptyStoreReturnsEmptyArray() async {
        let store = SentTaskLogStore(directory: tempDir)
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }
}
