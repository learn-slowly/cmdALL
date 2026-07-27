# Omnisearch 검색 결과를 정렬 가능한 표로 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

- 날짜: 2026-07-27
- 상태: **구현 착수 전 — 설계 문서와 함께 사용자 승인 대기.** 이 계획 문서 자체는 실행되지 않았다(작성만 완료).
- 설계 문서: `docs/superpowers/specs/2026-07-27-omnisearch-results-table-design.md`
- 상위 맥락: `.gjc/context/docufinder-parity-20260727T021555Z.md` (Docufinder 격차 7개 중 1번)

---

## 쉬운 말 요약 (레고용)

- **이번에 할 일**: 검색창(⇧⌘O)에서 파일 이름으로 찾은 결과들을, 파인더 "목록 보기"처럼 이름/경로/크기/수정일 네 칸으로 나뉜 표로 보이게 만든다. 칸 제목을 누르면 정렬되고, 칸 사이 경계선을 끌면 폭도 바뀐다.
- **이번엔 안 할 일**: 파일 내용으로 찾은 결과(본문 검색)는 지금 모양 그대로 둔다. "종류"(파일 형식) 칸은 이번엔 안 넣는다. 칸 폭을 다음에 다시 열어도 기억하게 저장하는 것도 안 한다. Docufinder 나머지 6개 기능(드래그아웃·AI 요약 등)도 이번엔 손 안 댄다.
- **순서**: 아래 태스크를 하나씩 순서대로 만든다. 각 태스크가 끝날 때마다 자동 검사(테스트)를 돌려서 기존에 되던 게 안 깨졌는지 확인하고, 확인되면 그 단위로 저장(커밋)한다. 마지막에 실제로 검색창을 열어서 눈으로 한 번 더 확인(수동 확인)한다.
- **지금 상태**: 이 계획은 아직 **실행 전**이다. 레고가 이 문서와 설계 문서를 보고 승인해야 실제 코드 작업이 시작된다.

---

**Goal:** Omnisearch(⇧⌘O)의 파일명 검색 결과를 정렬 가능·너비 조절 가능한 칼럼형 표로 바꾼다. 본문 검색(In-file Matches) 결과·화살표 탐색·엔터로 열기·클릭으로 열기는 지금 동작을 정확히 유지한다(회귀 없음).

**Architecture:** 설계 문서 §4 결정에 따라 SwiftUI `Table`을 새로 들이지 않고, 이미 검증된 `LibraryView`의 클릭/호버/정렬 헤더 패턴을 확장한다. `Hit`을 `OmnisearchHit`로 승격해 `Sources/Models/`로 옮기고, 정렬은 `LibrarySort`/`LibrarySorting`과 같은 모양으로 `OmnisearchSort`(모델) + `OmnisearchHitSorting`(순수 정렬 함수)로 분리해 단위 테스트가 가능하게 한다. 화면 쪽(헤더·칼럼 행·폭 조절 핸들)은 `OmnisearchView.swift` 안에 신설한다.

**Tech Stack:** Swift 5.9+ / SwiftUI, XCTest. 새 패키지 의존성 없음.

## Global Constraints

- 새 패키지 의존성 0.
- macOS 14+ / Swift 5.9+.
- 코드 주석·커밋 메시지·UI 문구는 **한국어**.
- 글에서 '박다/박는다/박았다' 표현은 쓰지 않는다.
- **본문 검색(In-file Matches) 섹션·`open(at:in:)`·`moveSelection`·`scheduleContentSearch`는 손대지 않는다** — 이번 변경은 파일명 검색 결과(fileHits)의 표시 방식에만 한정.
- 신규 기능은 가능한 한 **별도 파일**로 분리한다(`OmnisearchHit`·`OmnisearchSort`·`OmnisearchHitSorting`).
- 각 태스크는 `swift test` 전체 통과로 끝난다. **기준선은 구현 착수 시점에 `swift test` 전체 실행으로 재확인 후 Task 1에 기록**(이 계획 문서는 구현 착수 전 작성이라 아직 미확정 — 2026-07-25 시점 참고값은 872개였으나 그 뒤 변경됐을 수 있음).
- 테스트는 XCTest, `@testable import CmdMD`.
- 칼럼 폭·정렬 상태는 저장하지 않는다(세션 한정, §설계 문서 §5.3/§5.4) — 새 저장 파일·설정 키를 만들지 않는다.

---

## 파일 구조

**새로 만드는 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Models/OmnisearchHit.swift` | `OmnisearchHit`(옛 `OmnisearchView.Hit` — 최상위로 승격, `sizeBytes`/`modifiedAt` 필드 추가) |
| `Sources/Models/OmnisearchSort.swift` | `OmnisearchSortKey`(relevance/name/path/size/modifiedAt)·`OmnisearchSort`(키+방향, `selecting(_:)`) |
| `Sources/Services/OmnisearchHitSorting.swift` | `OmnisearchHit` 배열을 `OmnisearchSort` 기준으로 정렬하는 순수 함수 |
| `Tests/CmdMDTests/OmnisearchSortTests.swift` | 정렬 키 전환·방향 토글·기본값·`OmnisearchHitSorting` 실제 정렬 결과 테스트 |

**손대는 기존 파일** (전부 최소 변경)

| 파일 | 변경 |
|---|---|
| `Sources/Views/OmnisearchView.swift` | `Hit` 삭제(→ `OmnisearchHit`로 대체), `fileHits`에 크기·수정일 채우기 + 정렬 적용, 칼럼 헤더·칼럼 행·폭 조절 핸들 뷰 신설, 팝업 프레임 크기 조정 |

---

## Task 1: `OmnisearchHit` 모델 승격 (동작 변경 없음)

**목적:** 뒤 태스크들이 뷰 파일 밖에서 순수 함수로 테스트할 수 있도록, 지금 `OmnisearchView` 안에 갇힌 `Hit`을 최상위 모델로 꺼낸다. 이 태스크는 **이름 바꾸기 + 파일 이동만** — 동작·화면은 지금과 완전히 동일해야 한다.

**Files:**
- Create: `Sources/Models/OmnisearchHit.swift`
- Modify: `Sources/Views/OmnisearchView.swift`

**Interfaces:**
- Produces: `OmnisearchHit`(`Identifiable`) — `id`(UUID) · `kind`(enum: file/content) · `title`(String) · `subtitle`(String) · `url`(URL) · `line`(Int?)

- [ ] **Step 1: 기준선 확인**

Run: `swift test` (전체) → 통과 개수를 이 문서 상단 Global Constraints의 기준선 자리에 기록한다(구현 착수 시 첫 작업).

- [ ] **Step 2: 모델 파일 생성**

`Sources/Models/OmnisearchHit.swift`:

```swift
import Foundation

/// Omnisearch(⇧⌘O) 결과 한 줄. 파일명 매치(file)와 본문 매치(content) 공용.
/// 원래 OmnisearchView 안의 Hit이었으나, 정렬 로직(OmnisearchHitSorting)을
/// 뷰 밖에서 순수 함수로 테스트하기 위해 최상위 모델로 승격(스펙 §5.1).
struct OmnisearchHit: Identifiable {
    enum Kind {
        case file
        case content
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
    let line: Int?
}
```

- [ ] **Step 3: `OmnisearchView.swift`에서 `Hit` 참조를 전부 `OmnisearchHit`로 교체**

`OmnisearchView` 안의 `struct Hit { ... }` 선언을 삭제하고, `Hit(...)` 생성 호출·`OmnisearchView.Hit` 타입 참조(예: `OmnisearchRow`의 `let hit: OmnisearchView.Hit`)를 전부 `OmnisearchHit`로 바꾼다. 로직은 한 글자도 바꾸지 않는다(순수 치환).

- [ ] **Step 4: 빌드+테스트 확인**

Run: `swift build` → 성공.
Run: `swift test` → Step 1과 같은 개수, 실패 0(이름만 바꿨으므로 동작 차이 없음).

- [ ] **Step 5: 수동 스모크**

⇧⌘O로 검색창을 열어 최근 파일 목록·검색어 입력 시 결과·본문 검색·화살표/엔터/클릭 열기가 지금과 동일하게 동작하는지 확인(이 태스크는 순수 리팩터라 화면이 1px도 달라지면 안 된다).

- [ ] **Step 6: 커밋**

`git commit -m "리팩터: Omnisearch Hit을 OmnisearchHit 모델로 승격(동작 변경 없음)"`

---

## Task 2: `OmnisearchSort` + `OmnisearchHitSorting` (TDD)

**목적:** 정렬 키·방향 상태와, 그 상태로 `OmnisearchHit` 배열을 정렬하는 순수 함수를 만든다. 이 태스크는 아직 화면에 연결하지 않는다 — 다음 태스크에서 배선.

**Files:**
- Create: `Sources/Models/OmnisearchSort.swift`
- Create: `Sources/Services/OmnisearchHitSorting.swift`
- Test: `Tests/CmdMDTests/OmnisearchSortTests.swift`

**Interfaces:**
- Consumes: `OmnisearchHit`(Task 1)
- Produces:
  - `OmnisearchSortKey`(`enum`: `.relevance, .name, .path, .size, .modifiedAt`)
  - `OmnisearchSort`(`struct`: `key: OmnisearchSortKey`, `ascending: Bool`, `static let default`, `func selecting(_:) -> OmnisearchSort`)
  - `OmnisearchHitSorting.sorted(_ hits: [OmnisearchHit], by sort: OmnisearchSort) -> [OmnisearchHit]`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/CmdMDTests/OmnisearchSortTests.swift`:

```swift
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
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `swift test --filter OmnisearchSortTests`
Expected: 컴파일 실패 — `OmnisearchSort`/`OmnisearchHitSorting` 없음.

- [ ] **Step 3: `OmnisearchSort` 모델을 만든다**

`Sources/Models/OmnisearchSort.swift`:

```swift
import Foundation

/// Omnisearch 표(스펙 §5.3) 정렬 키. relevance = 지금과 같은 기본 순서(최근파일/이름유사도).
enum OmnisearchSortKey {
    case relevance, name, path, size, modifiedAt
}

/// 정렬 상태(키+방향). `LibrarySort`(라이브러리 화면)와 같은 토글 규칙이지만,
/// 이 값은 세션 한정 — 저장하지 않는다(팝업이 닫히면 사라짐).
struct OmnisearchSort: Equatable {
    var key: OmnisearchSortKey
    var ascending: Bool

    init(key: OmnisearchSortKey = .relevance, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    static let `default` = OmnisearchSort()

    /// 키별 기본 방향 — 이름·경로는 오름차순, 크기·수정일은 내림차순(큰 것/최신 것 먼저).
    static func defaultAscending(for key: OmnisearchSortKey) -> Bool {
        switch key {
        case .size, .modifiedAt: return false
        case .relevance, .name, .path: return true
        }
    }

    /// 헤더 버튼이 공유하는 전이 규칙 — 같은 키 재클릭은 방향 반전, 다른 키는 그 키 기본 방향.
    func selecting(_ newKey: OmnisearchSortKey) -> OmnisearchSort {
        if newKey == key {
            return OmnisearchSort(key: key, ascending: !ascending)
        }
        return OmnisearchSort(key: newKey, ascending: Self.defaultAscending(for: newKey))
    }
}
```

- [ ] **Step 4: `OmnisearchHitSorting` 함수를 만든다**

`Sources/Services/OmnisearchHitSorting.swift`:

```swift
import Foundation

/// Omnisearch 파일명 결과 정렬(스펙 §5.1.1). relevance는 원본 순서를 그대로 둔다 —
/// fileHits가 이미 관련도/최근순으로 조립해 둔 순서를 이 함수가 흐트러뜨리지 않는다는 게 핵심 보장.
enum OmnisearchHitSorting {
    static func sorted(_ hits: [OmnisearchHit], by sort: OmnisearchSort) -> [OmnisearchHit] {
        guard sort.key != .relevance else { return hits }

        return hits.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sort.key {
            case .relevance:
                result = .orderedSame // 도달 불가(위에서 선분기)
            case .name:
                result = lhs.title.localizedStandardCompare(rhs.title)
            case .path:
                result = lhs.subtitle.localizedStandardCompare(rhs.subtitle)
            case .size:
                result = compare(lhs.sizeBytes ?? 0, rhs.sizeBytes ?? 0)
            case .modifiedAt:
                result = compare(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast)
            }
            return sort.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
```

주의: 이 함수가 컴파일되려면 Task 3에서 `OmnisearchHit`에 `sizeBytes`/`modifiedAt` 필드를 추가해야 한다 — **Task 2와 Task 3은 실질적으로 함께 커밋**(아래 Task 3 Step에서 필드 추가 후 이 파일이 처음으로 빌드된다). 순서상 정렬 규칙을 먼저 확정하고 필드는 다음 태스크에서 채운다.

- [ ] **Step 5: 통과 확인**

Run: `swift test --filter OmnisearchSortTests` → Task 3 완료 후 전체 통과(필드가 없으면 컴파일 실패 상태로 남는다 — 정상, Task 3에서 마무리).

---

## Task 3: `OmnisearchHit`에 크기·수정일 채우기 + 정렬 배선

**목적:** `fileHits` 조립 시 `FileInfoService.loadBasic(url:)`로 크기·수정일을 채우고, `OmnisearchModel`에 정렬 상태를 추가해 `OmnisearchHitSorting`을 실제로 적용한다. 이 태스크가 끝나면 Task 2의 테스트가 컴파일·통과된다.

**Files:**
- Modify: `Sources/Models/OmnisearchHit.swift`
- Modify: `Sources/Views/OmnisearchView.swift`

- [ ] **Step 1: `OmnisearchHit`에 필드 추가**

`sizeBytes: Int64?`, `modifiedAt: Date?`을 추가(둘 다 기본값 `nil` — 본문 검색 결과는 채우지 않으므로).

- [ ] **Step 2: `OmnisearchSortTests` 컴파일+통과 확인**

Run: `swift test --filter OmnisearchSortTests` → 전체 통과(Task 2에서 작성해 둔 테스트).

- [ ] **Step 3: `fileHits`에 메타데이터 채우기**

`fileHits` 계산 프로퍼티의 각 `OmnisearchHit(...)` 생성 지점(최근 파일 분기, 이름유사도 검색 분기) 양쪽에서 `FileInfoService.loadBasic(url:)`을 호출해 `sizeBytes`·`modifiedAt`을 채운다. `linkableNotes` 분기는 이미 `note.modifiedAt`이 있지만, 크기는 없으므로 어차피 `loadBasic` 호출이 필요 — 통일해서 두 분기 다 `loadBasic` 결과를 쓴다(코드 중복 최소화).

- [ ] **Step 4: `OmnisearchModel`에 정렬 상태 추가**

```swift
var sort = OmnisearchSort.default
```

- [ ] **Step 5: `fileHits`에 정렬 적용**

`fileHits` 계산 프로퍼티 마지막에 `OmnisearchHitSorting.sorted(builtHits, by: model.sort)`를 거쳐 반환하도록 바꾼다. `.relevance`(기본값)일 땐 함수가 원본을 그대로 돌려주므로(Task 2 Step 4) **기본 화면은 지금과 동일**하다.

- [ ] **Step 6: 빌드+전체 테스트**

Run: `swift build` → 성공.
Run: `swift test` → 기준선(Task 1 Step 1 기록) + 신규 6개, 실패 0.

- [ ] **Step 7: 수동 스모크**

⇧⌘O로 검색창 열기 → 지금까지는 화면에 크기·수정일이 안 보이므로(다음 태스크에서 화면 배선) 눈에 보이는 차이는 없어야 한다. 최근 파일·이름유사도 검색 순서가 이전과 동일한지 확인(정렬이 아직 relevance 고정이라 UI가 없어도 순서는 그대로여야 함).

- [ ] **Step 8: 커밋**

`git commit -m "기능: Omnisearch 결과에 크기·수정일 메타데이터 + 정렬 로직 추가(화면 미배선)"`

---

## Task 4: 칼럼 헤더 + 정렬 클릭 UI

**목적:** 이름/경로/크기/수정일 헤더 버튼을 만들어 `model.sort`를 갱신하는 클릭 동작을 연결한다. 이 태스크까지는 아직 칼럼형 행(Task 6)이 없으므로, 헤더만 임시로 파일 섹션 위에 얹어 놓고 검증한다.

**Files:**
- Modify: `Sources/Views/OmnisearchView.swift`

- [ ] **Step 1: `OmnisearchColumnHeader` 뷰 신설**

`LibraryView.sortHeaderButton`(`Sources/Views/LibraryView.swift:138`)과 같은 모양 — 텍스트 + 현재 정렬 키일 때만 방향 화살표(`chevron.up`/`chevron.down`), 클릭 시 `model.sort = model.sort.selecting(key)`. 이름(가변폭, `.frame(maxWidth: .infinity, alignment: .leading)`) · 경로 · 크기 · 수정일(우측정렬) 4개를 가로로 배치.

- [ ] **Step 2: 파일 섹션 헤더 자리에 배선**

"Files/Recent" `OmnisearchSectionHeader` 아래(파일 행들 위)에 `OmnisearchColumnHeader(sort: $model.sort)`를 넣는다. `@Bindable var model = model`이 이미 `body` 안에 있으므로 바인딩 가능.

- [ ] **Step 3: 빌드+전체 테스트**

Run: `swift build` → 성공.
Run: `swift test` → 실패 0(UI 전용 변경이라 신규 테스트 없음 — Task 2 테스트가 이미 로직을 보장).

- [ ] **Step 4: 수동 스모크**

⇧⌘O → 헤더 4칸이 보이는지, "크기"·"수정일" 클릭 시 화면이 재정렬되는지(아직 칼럼형 행이 아니라 기존 2줄 행 순서만 바뀜), 재클릭 시 방향이 뒤집히는지, 화살표/엔터/클릭 열기가 여전히 되는지.

- [ ] **Step 5: 커밋**

`git commit -m "기능: Omnisearch 칼럼 헤더 + 클릭 정렬 배선"`

---

## Task 5: 칼럼 폭 조절 핸들

**목적:** 칼럼(경로/크기/수정일) 사이 경계를 드래그해 폭을 조절하는 기능을 추가한다.

**Files:**
- Modify: `Sources/Views/OmnisearchView.swift`

- [ ] **Step 1: `OmnisearchColumnResizeHandle` 뷰 신설**

작은 세로 막대(호버 시 커서 변경, `NSCursor.resizeLeftRight` 유사 처리) + `DragGesture`로 인접 칼럼 폭(`@State` 바인딩)을 갱신. 최소 폭(60pt) 클램프.

- [ ] **Step 2: 칼럼 폭 상태 추가**

`OmnisearchView`에 `@State private var columnWidths = (path: 200.0, size: 80.0, modifiedAt: 130.0)`(가칭 — 실제 구현 시 화면 보고 조정) 추가. `OmnisearchColumnHeader`와 (Task 6의) 칼럼 행 양쪽이 이 값을 읽어 폭을 맞춘다.

- [ ] **Step 3: 헤더에 핸들 배선**

경로/크기/수정일 칼럼 사이에 핸들을 끼워 넣는다(이름 칼럼은 가변폭이라 핸들 없음 — 설계 §5.4).

- [ ] **Step 4: 빌드+전체 테스트**

Run: `swift build` → 성공.
Run: `swift test` → 실패 0.

- [ ] **Step 5: 수동 스모크**

칼럼 경계를 드래그해 폭이 바뀌는지, 최소 폭 아래로 안 줄어드는지, 나머지 동작(정렬·클릭 열기)이 안 깨졌는지.

- [ ] **Step 6: 커밋**

`git commit -m "기능: Omnisearch 칼럼 폭 드래그 조절 추가"`

---

## Task 6: 파일 행을 칼럼형으로 교체 + 팝업 크기 조정

**목적:** 지금 2줄(제목+부제목) `OmnisearchRow`를 파일 종류에 한해 4칼럼 `OmnisearchFileRow`로 바꾼다. 클릭=열기·호버=하이라이트·선택 강조 배선은 기존 코드를 값만 바꿔 그대로 옮긴다(설계 §4 결정 — 이 태스크가 회귀 위험이 가장 큰 지점이므로 가장 신중하게).

**Files:**
- Modify: `Sources/Views/OmnisearchView.swift`

- [ ] **Step 1: `OmnisearchFileRow` 뷰 신설**

기존 `OmnisearchRow`의 `hit: OmnisearchHit`·`isSelected: Bool` 인터페이스를 그대로 따르되, 본문(`VStack` 2줄) 대신 이름/경로/크기/수정일 4칸을 가로로 배치. `FileInfoService.formatSize(hit.sizeBytes ?? 0)`, `hit.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "--"`로 표시. 아이콘·선택 강조색(`Color.cmdsAccent`/`cmdsAccentOn`)·`.padding`/`.clipShape` 등 스타일은 `OmnisearchRow`와 동일하게 맞춘다.

- [ ] **Step 2: 렌더링 분기에서 교체**

`body`의 `ForEach(hits) { ... }` 안에서 `hit.kind == .file`이면 `OmnisearchFileRow`, `.content`면 기존 `OmnisearchRow`를 그린다. `.onHover`·`.onTapGesture`(선택 갱신·`open(at:in:)` 호출)는 지금처럼 `ForEach` 레벨에 그대로 둔다(행 뷰 종류와 무관 — 옮길 필요 없음).

- [ ] **Step 3: 팝업 프레임 크기 조정**

`.frame(width: 560, height: 440)`을 칼럼 4개가 들어가도록 넓힌다(예: `width: 760, height: 480` — 실제로 띄워보고 잘림 없는 값으로 확정).

- [ ] **Step 4: 빌드+전체 테스트**

Run: `swift build` → 성공.
Run: `swift test` → 기준선 + 신규 6개, 실패 0.

- [ ] **Step 5: 수동 회귀 체크리스트 (자동 테스트로는 원리상 불가)**

- [ ] ⇧⌘O로 검색창 열기 → 빈 검색어에서 최근 파일이 표 형태(이름/경로/크기/수정일)로 보임
- [ ] 검색어 입력 → 이름 유사도 결과가 같은 표 형태로 보임, 검색어 지우면 다시 최근 파일 표로 복귀
- [ ] "이름"/"경로"/"크기"/"수정일" 헤더 클릭 → 각각 기준으로 정렬, 재클릭 시 방향 반전
- [ ] 칼럼 경계 드래그로 폭 조절
- [ ] 화살표 위/아래로 하이라이트 이동(파일 행 ↔ 본문 검색 행 경계 포함), 엔터로 하이라이트된 항목 열림
- [ ] 마우스 호버 시 하이라이트 이동, **클릭 한 번**으로 즉시 열림(더블클릭 아님)
- [ ] 2글자 이상 입력 시 본문 검색(In-file Matches) 결과가 지금처럼 줄 번호+스니펫 목록으로 보임(표로 안 바뀜)
- [ ] 검색 결과 0건일 때 안내 문구(`ContentUnavailableView`) 정상 표시
- [ ] ESC로 창 닫기 정상 동작

- [ ] **Step 6: 최종 커밋**

`git commit -m "기능: Omnisearch 파일명 검색 결과를 정렬 가능한 표로 전환"`

---

## 최종 통합

- [ ] `swift test` 전체 재실행, 기준선 대비 정확히 +6(Task 2 테스트) 확인.
- [ ] `CmdMD-fork_prd.md` §10 "Docufinder 대비 기능 격차" 1번 항목에 완료 표기 추가(다른 완료 항목과 같은 형식).
- [ ] 레고에게 실제 화면(스크린샷 또는 실행 화면)으로 최종 확인받기.

## 이번에 하지 않을 것

- 본문 검색 결과(In-file Matches)를 표로 바꾸는 것 — 설계 문서 §7 참고, 원한다면 별도 조각.
- "종류"(파일 형식) 칼럼 추가 — PRD 원문엔 있으나 이번 작업 지시 범위 밖(설계 문서 §7).
- 칼럼 폭·정렬 상태를 저장해 다음에 다시 열어도 기억하게 하는 것 — 세션 한정.
- SwiftUI `Table`로 다시 만들기 — 설계 문서 §4에서 이번엔 보류로 결정, 필요해지면 재검토.
- Docufinder 격차 7개 중 나머지 6개(드래그아웃·AI 요약·OCR·이메일 검색·원본 렌더·버전 비교) — 각각 별도 조각.
