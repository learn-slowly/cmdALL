# Omnisearch 검색 결과를 정렬 가능한 표로 (설계)

- 날짜: 2026-07-27
- 상태: 설계 승인 대기
- 상위 맥락: `.gjc/context/docufinder-parity-20260727T021555Z.md`(Docufinder 기능 격차 7개, 합의된 착수 순서 — 이 문서는 1번 항목)
- 근거 원문: `CmdMD-fork_prd.md` §10 "Docufinder 대비 기능 격차" 1번 — "파일명 검색 결과를 정렬 가능한 표(이름·경로·크기·수정일·종류 칼럼, 너비 조절)로 보기 — cmdALL은 지금 단순 리스트(Omnisearch)."

---

## 쉬운 말 요약 (레고용)

- **지금**: 단축키(⇧⌘O)로 검색창을 열면, 찾은 파일들이 그냥 위아래로 나열된 줄 목록으로 뜬다. 파일 이름 밑에 폴더 경로가 작게 붙어있는 정도다. 크기·수정한 날짜는 아예 안 보인다.
- **바뀐 뒤**: 파인더의 "목록 보기"처럼, 이름 / 경로 / 크기 / 수정일 네 칸으로 나뉜 표로 보인다. 칸 제목(예: "크기")을 누르면 그 기준으로 정렬되고, 한 번 더 누르면 반대 순서로 뒤집힌다. 칸 사이 경계선을 드래그하면 폭도 조절할 수 있다.
- **그대로 유지**: 검색창에 타이핑하면 파일 이름이 비슷한 것들이 뜨는 기능, 검색창을 비워두면 최근 연 파일이 뜨는 기능, 파일 내용으로 찾는 기능(본문 검색), 화살표로 고르고 엔터로 여는 기능 — 전부 지금과 똑같이 동작한다. 아무것도 안 깨진다.
- **이번엔 안 하는 것**: 본문 검색 결과(파일 안 특정 줄을 찾아주는 부분)는 표로 안 바꾼다 — 원래 요청("파일명 검색 결과")이 이름 목록에 관한 것이라 그 부분만 바꾼다. "종류"(문서 형식) 칸도 이번엔 안 넣는다(참고 문서엔 있지만, 이번 작업 지시엔 이름/경로/크기/수정일 네 칸만 정해져 있어서 그대로 따랐다 — 필요하면 다음에 추가). 칸 폭을 조절한 걸 다음에 다시 열어도 기억하게 저장하는 것도 이번엔 안 한다(창을 닫으면 초기화).
- **이번 산출물**: 코드는 안 건드리고, "이렇게 만들겠다"는 설계 문서와 "무슨 순서로 만들겠다"는 계획 문서 두 개만 작성한다. 실제 화면이 바뀌는 건 이 문서들을 레고가 확인하고 승인한 다음이다.

---

## 1. 목적 (왜)

Docufinder를 보고 사용자가 "이것처럼 되고 싶다"고 지목한 기능 격차 7개 중 1번. 지금 Omnisearch(⇧⌘O)는 파일 이름 검색 결과를 단순 세로 목록으로만 보여줘서, 여러 개가 잡혔을 때 크기순·최신순으로 훑어볼 방법이 없다. Docufinder는 이걸 정렬·너비 조절이 되는 표로 보여준다 — cmdALL도 같은 편의를 들인다.

## 2. 무엇을 바꾸나 (범위)

- 대상: `Sources/Views/OmnisearchView.swift`의 **파일명 검색 결과**(`fileHits` — 최근 파일 + 이름 유사도 검색)만.
- 칼럼: 이름 · 경로 · 크기 · 수정일 (팀 작업 지시에 명시된 4개, 아래 §7 참고).
- 칼럼 헤더 클릭 → 그 기준 정렬, 재클릭 → 방향 반전. 기본은 지금과 동일한 순서(관련도/최근순 — 아래 §4.2).
- 칼럼 경계 드래그 → 폭 조절.
- 본문 검색 결과("In-file Matches" 섹션)는 지금 모양(파일명 + 줄 번호 + 스니펫 한 줄) 그대로 유지 — 표로 바꾸지 않는다(§7).

## 3. 실측 — 지금 구조 확인

- 검색창은 `Sources/Views/OmnisearchView.swift`의 `OmnisearchView`(뷰) + `OmnisearchModel`(`@Observable` 상태: query·selectedIndex·contentResults 등)로 구성. `.sheet(isPresented: $state.showOmnisearch) { OmnisearchView() }`(`ContentView.swift:79`)로 뜨는 고정 크기(560×440) 팝업.
- `Hit`(뷰 내부 구조체)은 `kind`(file/content) · `title` · `subtitle` · `url` · `line`만 가진다. 크기·수정일 필드가 없다.
- `fileHits`(계산 프로퍼티): 검색어 없으면 `appState.recentFiles`(URL 배열, 크기·날짜 캐시 없음) 최근 8개. 검색어 있으면 `appState.linkableNotes`(`[VaultNote]` — `path`·`title`·`modifiedAt`·`url`은 있지만 파일 크기는 없음)를 `Command.fuzzyScore`로 점수 매겨 정렬 후 상위 10개.
- `contentHits`: `model.contentResults`(`[SearchResult]`, 본문 검색 — 줄 번호+스니펫)를 그대로 12개까지 매핑. **이번 작업 범위 밖.**
- 화면은 `allHits = fileHits + contentHits`를 한 세로 목록(`ScrollView` + `ForEach`)에 "Files/Recent" 헤더 → 파일 행들 → "In-file Matches" 헤더 → 본문 행들 순으로 그린다. 키보드 위/아래(`moveSelection`)·엔터(`open(at:in:)`)는 이 `allHits` 배열의 인덱스 하나로 파일/본문 구분 없이 동작한다. 마우스는 `.onHover`로 하이라이트, `.onTapGesture`로 즉시 열기(더블클릭 아님 — 한 번 클릭으로 연다).
- 크기·수정일을 보여주려면 파일 메타데이터가 필요한데, 이미 저장소에 정확히 맞는 헬퍼가 있다: `FileInfoService.loadBasic(url:)`(`Sources/Services/FileInfoService.swift:20`)가 `resourceValues` 한 번 호출로 `sizeBytes`·`modifiedAt`을 함께 준다. 표시 형식도 이미 있다: `FileInfoService.formatSize(_:)`(파인더식 크기 문자열), 수정일은 다른 화면들(`SettingsView.swift:976`, `WikiIngestView.swift:188`)이 쓰는 `date.formatted(date: .abbreviated, time: .shortened)` 그대로 재사용.
- 정렬 가능한 칼럼 목록은 이번이 처음이 아니다 — `LibraryView.swift`(라이브러리 화면 "목록 보기")가 이미 `LibrarySortKey`(`Sources/Models/LibrarySort.swift`) + `LibrarySort.selecting(_:)`(같은 키 재클릭 시 방향 반전) + `sortHeaderButton`(헤더 버튼, 화살표 아이콘으로 방향 표시) 패턴으로 이름/수정일/크기 정렬을 이미 구현·출시했다. 다만 그 칼럼 폭은 **고정값**(`frame(width: 92)` 등)이라 드래그로 조절하는 코드는 아직 저장소 어디에도 없다(신규).

## 4. 대안 비교 — 표를 어떻게 만들 것인가

세 가지를 검토했다.

| 안 | 설명 | 장점 | 단점 |
|---|---|---|---|
| **A. SwiftUI `Table`(애플 표준 표 컴포넌트)** | `Table(fileHits, selection:) { TableColumn(...) }`로 새로 작성 | 칼럼 폭 드래그·정렬 표시가 애플이 기본 제공(공짜) | 이 저장소에 `Table` 사용 사례가 **0건**(신규 패턴). 현재 "한 번 클릭=열기, 마우스오버=하이라이트, 화살표+엔터=키보드 탐색"이라는 커스텀 상호작용을 `Table`의 행 단위로 그대로 옮길 수 있는지 검증된 바 없음 — 잘못 옮기면 "엔터로 열기·화살표 이동" 회귀 위험이 가장 큼 |
| **B. 기존 `LibraryView` 패턴 확장(선택)** | `sortHeaderButton`/`LibrarySortKey`와 같은 모양의 헤더+정렬을 새로 만들고, 기존 `OmnisearchRow`의 클릭·호버 배선은 그대로 둔 채 한 줄(제목+부제목 2줄) 대신 칼럼 4개짜리 가로 행으로 바꾼다. 칼럼 폭 조절만 새로 만든다(드래그 핸들, 작고 독립적인 컴포넌트) | 클릭=열기, 호버=하이라이트, 화살표+엔터 탐색을 **코드 변경 없이 그대로 재사용** → 회귀 위험 최소. 정렬 버튼도 이미 검증된 `LibrarySort.selecting` 패턴을 이름만 바꿔 재사용 | 칼럼 폭 드래그만 새로 작성해야 함(다만 범위가 작고 격리된 코드) |
| **C. AppKit `NSTableView`(NSViewRepresentable)** | 완전히 새로 감싸서 구현 | 가장 유연 | 이번 범위(칼럼 4개, 정렬+너비조절)에 비해 과함, 코드량·유지보수 부담 가장 큼 |

**결정: B안.** "기존 동작 회귀 없음"이 이번 작업의 최우선 제약이라, 이미 검증된 클릭/호버/키보드 배선을 그대로 쓰는 B가 가장 안전하다. A(`Table`)는 애플이 폭 조절을 공짜로 주지만, 이 코드베이스에 선례가 없어 상호작용 이관 위험을 이번 작업에서 떠안기보다 **차후 조각(칼럼 폭 저장 등 더 키울 때)에 재검토**하는 쪽으로 미룬다.

## 5. 설계 상세

### 5.1 데이터 — `Hit`에 필드 추가

```swift
struct Hit: Identifiable {
    ...
    var sizeBytes: Int64?
    var modifiedAt: Date?
}
```

`fileHits` 조립 시 각 URL에 대해 `FileInfoService.loadBasic(url:)`을 한 번 호출해 `sizeBytes`·`modifiedAt`을 채운다(§3에서 확인한 기존 헬퍼 재사용 — 새 파일 스캔 코드를 만들지 않는다). 대상이 최대 10개(`recentFiles.prefix(8)` / `linkableNotes` 상위 10개)라 매 렌더마다 동기 호출해도 비용은 `LibraryListing`/`FileScanner`가 이미 하는 수준과 같다(신규 성능 리스크 아님).

`contentHits`(본문 검색)는 이번 범위 밖이라 `sizeBytes`/`modifiedAt`을 채우지 않는다(nil로 둠, 화면에서도 안 씀).

### 5.2 정렬 상태 — `OmnisearchSort` (신규, `Sources/Models/OmnisearchSort.swift`)

`LibrarySortKey`/`LibrarySort`와 같은 모양으로 새로 만든다(다른 화면 것과 섞어 쓰지 않음 — Omnisearch 전용).

```swift
enum OmnisearchSortKey { case relevance, name, path, size, modifiedAt }

struct OmnisearchSort: Equatable {
    var key: OmnisearchSortKey = .relevance
    var ascending: Bool = true

    static let `default` = OmnisearchSort()
    func selecting(_ newKey: OmnisearchSortKey) -> OmnisearchSort { ... } // LibrarySort.selecting과 동일 토글 규칙
}
```

- 기본값은 `.relevance`. 이 상태에서는 **지금 fileHits 순서를 손대지 않는다**(최근파일 8개 순서 / 이름유사도 점수순 그대로) — 이번 변경이 "기본 화면은 지금과 똑같이 보인다"는 걸 보장하는 핵심 장치.
- 이름·경로·크기·수정일 칼럼 헤더 클릭 시 그 키로 전환, `fileHits` 배열을 해당 기준으로 재정렬한 뒤 화면에 그린다. 같은 칼럼 재클릭 = 방향 반전(오름차순↔내림차순), 다른 칼럼 클릭 = 그 칼럼 기본 방향(이름/경로는 오름차순, 크기/수정일은 내림차순 — `LibrarySort.defaultAscending` 관례와 동일하게 큰 것/최신 것 먼저).
- `allHits = fileHits + contentHits`는 (재정렬된) `fileHits`를 그대로 이어붙이므로, 화살표 이동·엔터로 열기 인덱스는 **정렬 후에도 화면에 보이는 순서와 항상 일치**한다(별도 동기화 코드 불필요 — 단일 진실원).
- **저장 안 함**: `LibrarySort`(라이브러리 화면)와 달리 폴더별로 기억하지 않는다. `OmnisearchModel`은 팝업이 열릴 때마다 새로 생성되는 `@State`라 자연히 세션 한정 — 검색창을 닫았다 다시 열면 정렬은 관련도 기본값으로 리셋된다(§7에 "이번에 안 함"으로 명시).

### 5.3 화면 — 헤더 + 칼럼형 행

- 새 헤더 뷰(가칭 `OmnisearchColumnHeader`): "이름"(가변폭, 남는 공간 채움) · "경로"(고정폭, 조절가능) · "크기"(고정폭, 우측정렬) · "수정일"(고정폭, 우측정렬) 4개 버튼. `LibraryView.sortHeaderButton`과 같은 모양(텍스트 + 방향 화살표, 현재 정렬 키만 강조색).
- 칼럼 사이 경계에 드래그 핸들(가칭 `OmnisearchColumnResizeHandle`, 신규 소형 컴포넌트) — `DragGesture`로 폭을 늘리고 줄인다. 최소 폭(예: 60pt) 아래로는 안 줄어듦. "이름" 칼럼은 나머지 폭을 자동으로 채우는 가변 칼럼이라 자체 핸들이 없다(오른쪽 이웃 칼럼 핸들이 이름 칼럼 폭에 영향).
- 폭 상태는 뷰의 `@State`(딕셔너리 또는 구조체, 예: `columnWidths.path`, `.size`, `.modifiedAt`) — 세션 한정, 저장 안 함(§5.2와 동일 이유).
- 파일 행(가칭 `OmnisearchFileRow`, 기존 `OmnisearchRow`를 파일 종류에 한해 대체): 아이콘 + 이름 + 경로 + 크기(`FileInfoService.formatSize`) + 수정일(`.formatted(date: .abbreviated, time: .shortened)`) 4칸을 가로로 배치. **클릭=`open(at:in:)` 즉시 열기, 호버=하이라이트, 선택 강조색** 로직은 지금 `OmnisearchRow`에 있는 것을 값만 바꿔 그대로 옮긴다(§4 결정 이유).
- 본문 검색 행(`OmnisearchRow`, `.content` 종류)은 지금 그대로 둔다 — 파일 행 표 아래에 기존 모양 그대로 이어진다.
- 팝업 크기: 지금 560×440은 칼럼 4개를 넣기엔 좁다. 폭을 넓힌다(구체적 수치는 구현 시 실제로 띄워보고 정함 — 계획 문서 태스크에서 확정).

## 6. 파일 구조 (구현 시 예정)

**새로 만드는 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Models/OmnisearchSort.swift` | `OmnisearchSortKey`·`OmnisearchSort`(관련도 기본값 + 선택 시 토글) |
| `Tests/CmdMDTests/OmnisearchSortTests.swift` | 정렬 키 전환·방향 토글·기본값(relevance) 순수 로직 테스트 |

**손대는 기존 파일**

| 파일 | 변경 |
|---|---|
| `Sources/Views/OmnisearchView.swift` | `Hit`에 `sizeBytes`/`modifiedAt` 추가, `fileHits` 조립 시 `FileInfoService.loadBasic` 호출 + `OmnisearchSort` 적용, 헤더+칼럼 행 뷰 신설(`OmnisearchColumnHeader`/`OmnisearchFileRow`/`OmnisearchColumnResizeHandle`), 팝업 프레임 크기 조정. 본문 검색 섹션·`open`/`moveSelection`/`scheduleContentSearch` 로직은 **손대지 않음**(회귀 없음 원칙) |

## 7. 이번에 하지 않을 것

- 본문 검색 결과("In-file Matches")를 표로 바꾸는 것 — PRD 원문이 "**파일명** 검색 결과"라 이번 범위는 이름 목록에 한정. 원하면 다음 조각으로.
- "종류"(파일 형식) 칼럼 — PRD 원문(§10)엔 있지만, 이번 작업을 지시한 팀 브리프·컨텍스트 문서(`docufinder-parity-...md`)는 명시적으로 "이름/경로/크기/수정일" 4개만 합의된 범위로 못 박아뒀다. 5번째 칼럼을 넣을지는 사용자 확인 후 별도로 결정.
- 칼럼 폭을 다음에 다시 열어도 기억하도록 저장하는 것 — 이번엔 세션(팝업이 열려있는 동안)에만 유지.
- Docufinder 격차 7개 중 나머지(드래그아웃·AI 요약·OCR·이메일 검색·원본 렌더·버전 비교) — 전부 이번 조각 밖.
- 실제 Swift 코드 구현 — 이 문서와 계획 문서 작성까지만. 코드는 사용자 승인 후 별도 착수.

## 8. 검증 계획

- `OmnisearchSortTests`(신규): 기본값이 `.relevance`인지, 같은 키 재클릭 시 방향이 뒤집히는지, 다른 키 클릭 시 그 키의 기본 방향(이름/경로=오름차순, 크기/수정일=내림차순)으로 바뀌는지.
- 기존 `swift test` 전체 그린 유지 — 계획 문서에 착수 시점 기준선 개수 명시.
- 수동 스모크(자동 불가 영역): ⇧⌘O로 검색창 열기 → 빈 검색어에서 최근 파일이 지금과 같은 순서로 보이는지, 검색어 입력 시 이름 유사도 순서가 지금과 같은지, 칼럼 헤더 클릭 시 정렬 변경, 칼럼 경계 드래그 시 폭 조절, 화살표+엔터로 여전히 열리는지, 본문 검색(2글자 이상 입력) 결과가 지금처럼 스니펫 목록으로 나오는지, 마우스 클릭 한 번으로 여전히 즉시 열리는지.
