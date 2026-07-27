import XCTest
@testable import CmdMD

/// Omnisearch 표 정렬(스펙 §5.3/§5.1.1) — 기본값(relevance)은 순서를 건드리지 않고,
/// 칼럼 선택 시에만 재정렬한다는 게 핵심 보장.
final class OmnisearchSortTests: XCTestCase {

    private func hit(_ title: String, path: String = "/tmp", size: Int64, days: Int) -> OmnisearchHit {
        OmnisearchHit(
            kind: .file,
            title: title,
            subtitle: path,
            url: URL(fileURLWithPath: "\(path)/\(title)"),
            line: nil
        )
    }

    func test기본값은relevance이고오름차순이다() {
        XCTAssertEqual(OmnisearchSort.default.key, .relevance)
        XCTAssertTrue(OmnisearchSort.default.ascending)
    }

    func test같은키재선택은방향을뒤집는다() {
        let sort = OmnisearchSort(key: .name, ascending: true)
        let toggled = sort.selecting(.name)
        XCTAssertEqual(toggled.key, .name)
        XCTAssertFalse(toggled.ascending)
    }

    func test다른키선택은그키기본방향으로바뀐다() {
        let sort = OmnisearchSort(key: .name, ascending: false)
        let switched = sort.selecting(.size)
        XCTAssertEqual(switched.key, .size)
        XCTAssertFalse(switched.ascending) // 크기는 큰 것 먼저(내림차순) 기본
    }

    func testRelevance일때는원본순서를그대로둔다() {
        var hits: [OmnisearchHit] = []
        // 이름 사전순으로 정렬하면 원본과 달라지는 순서로 일부러 구성.
        hits.append(OmnisearchHit(kind: .file, title: "가나다", subtitle: "/tmp", url: URL(fileURLWithPath: "/tmp/1"), line: nil))
        hits.append(OmnisearchHit(kind: .file, title: "abc", subtitle: "/tmp", url: URL(fileURLWithPath: "/tmp/2"), line: nil))

        let sorted = OmnisearchHitSorting.sorted(hits, by: .default)
        XCTAssertEqual(sorted.map(\.title), hits.map(\.title)) // 원본 순서 유지
    }

    func test이름오름차순정렬() {
        let hits = [
            OmnisearchHit(kind: .file, title: "banana", subtitle: "/tmp", url: URL(fileURLWithPath: "/tmp/b"), line: nil),
            OmnisearchHit(kind: .file, title: "apple", subtitle: "/tmp", url: URL(fileURLWithPath: "/tmp/a"), line: nil),
        ]
        let sorted = OmnisearchHitSorting.sorted(hits, by: OmnisearchSort(key: .name, ascending: true))
        XCTAssertEqual(sorted.map(\.title), ["apple", "banana"])
    }

    func test경로내림차순정렬() {
        let hits = [
            OmnisearchHit(kind: .file, title: "a", subtitle: "/tmp/aa", url: URL(fileURLWithPath: "/tmp/aa/a"), line: nil),
            OmnisearchHit(kind: .file, title: "b", subtitle: "/tmp/zz", url: URL(fileURLWithPath: "/tmp/zz/b"), line: nil),
        ]
        let sorted = OmnisearchHitSorting.sorted(hits, by: OmnisearchSort(key: .path, ascending: false))
        XCTAssertEqual(sorted.map(\.subtitle), ["/tmp/zz", "/tmp/aa"])
    }
}
