import XCTest
@testable import CmdMD

/// 위키 재귀 페이지 목록(스펙 §2.6) — 하위 폴더 포함·숨김 제외·상대경로·이름순.
final class WikiPageListerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(root)
        super.tearDown()
    }

    private func touch(_ rel: String) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func testListsRecursivelyWithRelativePathsSorted() {
        touch("index.md")
        touch("references/신진욱2011.md")
        touch("references/Baker_1993.md")
        touch("claims/c1.md")
        touch("notes.txt")                       // 비md 제외
        let pages = WikiPageLister.relativePages(under: root)

        // 집합: 하위 폴더 재귀·상대경로·비md 제외.
        XCTAssertEqual(Set(pages), ["claims/c1.md",
                                    "index.md",
                                    "references/신진욱2011.md",
                                    "references/Baker_1993.md"])
        XCTAssertEqual(pages.count, 4)

        // 순서: 한글↔라틴 혼합 정렬은 로캘 종속이라 단정하지 않는다(정렬이 쓰는
        // localizedStandardCompare가 현재 로캘을 따른다). 실측: "Baker_1993.md" vs
        // "신진욱2011.md"만 ko에서 뒤·en에서 앞으로 뒤집히고 나머지 쌍은 전 로캘 고정 —
        // 그래서 한글 이름을 섞은 채 전체 배열을 단정하면 개발기(ko)는 통과·CI(en)는
        // 실패한다(T2 로캘 함정, 같은 파일 testExcludesRuleFilesFromTargets의 회피와 동일).
        // 로캘 무관하게 고정인 것만 검증한다.
        XCTAssertEqual(pages[0], "claims/c1.md")
        XCTAssertEqual(pages[1], "index.md")
        XCTAssertTrue(pages.dropFirst(2).allSatisfy { $0.hasPrefix("references/") })
    }

    func testSortsNaturallyWithinLocaleStableNames() {
        // "정렬된다"의 실질 검증 — localizedStandardCompare의 숫자 자연정렬(a2 < a10)을
        // 로캘에 흔들리지 않는 ASCII 이름으로 고정 검증한다(위 테스트가 순서 단정을
        // 뺀 만큼을 여기서 메운다). 실측: ko·en·POSIX 전부 같은 순서.
        touch("a10.md")
        touch("a2.md")
        touch("a1.md")
        touch("b/a2.md")
        touch("b/a10.md")
        XCTAssertEqual(WikiPageLister.relativePages(under: root),
                       ["a1.md", "a2.md", "a10.md", "b/a2.md", "b/a10.md"])
    }

    func testExcludesHiddenDirectoriesAndFiles() {
        touch(".git/objects/a.md")
        touch(".obsidian/config.md")
        touch(".hidden.md")
        touch("visible.md")
        XCTAssertEqual(WikiPageLister.relativePages(under: root), ["visible.md"])
    }

    func testHiddenFileDoesNotDropSiblingPages() {
        // .DS_Store(숨김 파일)가 낀 보이는 폴더의 페이지가 전부 반환돼야 한다 —
        // 숨김 파일에서 skipDescendants()를 부르면 감싸는 폴더 하강이 취소되는 회귀(Critical).
        // APFS 열거 순서 비결정 대비 .md를 여러 개 두어 skip 발화 후속 항목을 보장한다.
        touch("docs/.DS_Store")
        for name in ["a", "b", "c", "d", "e"] { touch("docs/\(name).md") }
        touch("visible.md")
        let pages = WikiPageLister.relativePages(under: root)
        XCTAssertEqual(pages, ["docs/a.md", "docs/b.md", "docs/c.md",
                               "docs/d.md", "docs/e.md", "visible.md"])
    }

    func testEmptyOrMissingRootReturnsEmpty() {
        XCTAssertEqual(WikiPageLister.relativePages(under: root), [])
        XCTAssertEqual(WikiPageLister.relativePages(
            under: root.appendingPathComponent("없는폴더")), [])
    }

    func testExcludesRuleFilesFromTargets() {
        // 루트 CLAUDE.md·templates/는 "규칙 소스"(규칙 파악이 읽는 파일)지 병합 대상이 아니다 —
        // Picker에 노출되면 규칙 파일에 실수로 병합하는 사고를 유인한다.
        touch("CLAUDE.md")
        touch("templates/summary.md")
        touch("templates/concept.md")
        touch("pages/주제/문서.md")
        touch("sub/CLAUDE.md")                   // 루트가 아닌 CLAUDE.md는 일반 페이지 취급
        touch("sub/templates/x.md")              // 루트가 아닌 templates도 일반 폴더 취급
        let pages = WikiPageLister.relativePages(under: root)
        // 혼합 문자 정렬은 로캘 종속이라 순서 대신 집합으로 비교(T2 로캘 함정 회피).
        XCTAssertEqual(Set(pages), ["pages/주제/문서.md", "sub/CLAUDE.md", "sub/templates/x.md"])
        XCTAssertEqual(pages.count, 3)
    }

    func testExcludesRuleFilesCaseInsensitively() {
        // collectRuleSources는 파일시스템 대소문자 무시 해석으로 소문자 규칙파일도 규칙 소스로
        // 읽는다 — 제외도 같은 시맨틱이어야 Picker에 새지 않는다(case-insensitive FS 방어).
        touch("claude.md")               // 소문자 CLAUDE.md
        touch("Templates/summary.md")    // 대문자 templates/
        touch("pages/문서.md")
        let pages = WikiPageLister.relativePages(under: root)
        XCTAssertEqual(pages, ["pages/문서.md"])
    }
}
