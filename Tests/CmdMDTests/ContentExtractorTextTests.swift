import XCTest
@testable import CmdMD

/// 글자 파일 색인 확장(스펙 §3.6).
final class ContentExtractorTextTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("색인테스트-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test글자파일본문을읽는다() throws {
        for (name, body) in [("설정.json", #"{"이름":"레고"}"#),
                             ("코드.swift", "let 인사 = \"안녕\""),
                             ("표.csv", "이름,나이\n레고,5"),
                             ("설정.yml", "키: 값")] {
            let url = try write(name, body)
            XCTAssertEqual(ContentExtractor.localBody(for: url), body, "\(name)을 읽어야 한다")
        }
    }

    func test기존형식은그대로읽는다() throws {
        let url = try write("노트.md", "# 제목")
        XCTAssertEqual(ContentExtractor.localBody(for: url), "# 제목")
    }

    func test미리보기갈래는읽지않는다() throws {
        let url = try write("발표.pptx", "가짜 내용")
        XCTAssertNil(ContentExtractor.localBody(for: url), "본문을 뽑을 수 없는 형식은 nil")
    }

    func test크기상한을넘으면읽지않는다() throws {
        let 큰글 = String(repeating: "가", count: ContentExtractor.maxTextBytes)  // UTF-8로 3배
        let url = try write("기록.log", 큰글)
        XCTAssertNil(ContentExtractor.localBody(for: url), "5MB 넘는 파일은 이름만 색인")
    }

    func test상한아래는읽는다() throws {
        let url = try write("기록.log", "짧은 기록")
        XCTAssertEqual(ContentExtractor.localBody(for: url), "짧은 기록")
    }
}
