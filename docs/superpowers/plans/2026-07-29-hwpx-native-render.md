# 한글(.hwpx) 원본 그대로 보기 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

- 날짜: 2026-07-29
- 상태: **코드 구현 완료(2026-07-29, Task 1~7 전부). swift test 953개 통과, 재패키징·`/Applications` 교체 설치 완료. 남은 건 레고님의 필수 수동 스모크(설계 문서 §8, 아래 Task 7 체크리스트) — 실제 한컴 저장 hwpx 파일로 확인해야 완결.**
- 설계 문서: `docs/superpowers/specs/2026-07-29-hwpx-native-render-design.md`
- 상위 맥락: `.gjc/context/docufinder-parity-20260727T021555Z.md`(Docufinder 격차 7개 중 5번, 2026-07-27 "불가능"으로 보류됐다가 2026-07-29 kordoc 최신 버전에서 재발견돼 재개)

---

## 쉬운 말 요약 (레고용)

- **이번에 할 일**: `.hwpx`(요즘 한글 파일) 문서를 열었을 때, MS 오피스처럼 "원본 보기" 버튼이 새로 생긴다. 누르면 kordoc이 그려주는 진짜 조판 모양(그림처럼)으로 보인다.
- **이번엔 안 할 일**: `.hwp`(옛날 방식 한글 파일)는 이번에도 안 된다 — kordoc에 그 기능 자체가 없다. 조판 캐시 없는 파일을 억지로 그려주는 것(reflow 자동 전환)도 이번엔 안 한다. 검색어 형광펜, 확대·축소 전용 버튼도 이번엔 안 넣는다.
- **순서**: 아래 태스크를 하나씩 순서대로 만든다. 태스크가 끝날 때마다 자동 검사(테스트)로 기존 기능이 안 깨졌는지 확인 후 그 단위로 저장(커밋)한다. 마지막에 레고님이 실제 한글 파일로 눌러봐야 완전히 끝난 걸로 친다(자동 검사로는 확인 못 하는 부분이 있음 — 설계 문서 §8 참고).
- **지금 상태**: 이 계획은 아직 **실행 전**이다. 레고가 이 문서와 설계 문서를 보고 승인해야 실제 코드 작업이 시작된다.

---

**Goal:** `.hwpx` 문서에 kordoc `render` 명령(SVG) 기반의 읽기 전용 "원본 보기" 화면을 추가한다. 기존 MS 오피스 원본 보기(QuickLook)·hwp/hwpx 편집·양식 채우기 동작은 전혀 건드리지 않는다(회귀 없음).

**Architecture:** 설계 문서 §5 결정에 따라 새 actor `KordocRenderService`가 기존 `KordocService.resolveNpxPath()`/`packageSpec`을 재사용해 `kordoc render`를 호출하고, 결과 SVG를 최소 HTML로 감싸 캐시한다. 상태는 `HwpxRenderState`(loading/loaded/failed) 모델로 `AppState.hwpxRenderStates`에 탭별로 보관하고, `OfficeReaderView`가 기존 원본 보기 토글(`officeShowingOriginal`)을 그대로 재사용하되 확장자에 따라 QuickLook과 신규 `HwpxRenderPreview`로 갈라진다.

**Tech Stack:** Swift 5.9+ / SwiftUI, WKWebView, XCTest. 새 패키지 의존성 없음.

## Global Constraints

- 새 패키지 의존성 0.
- macOS 14+ / Swift 5.9+.
- 코드 주석·커밋 메시지·UI 문구는 **한국어**.
- 글에서 '박다/박는다/박았다' 표현은 쓰지 않는다.
- **`.hwp`(구버전 바이너리) 관련 코드·화면은 손대지 않는다** — 원본 보기 버튼이 hwp에는 여전히 안 뜨는 것이 의도된 동작.
- **MS 오피스(doc/docx/xls/xlsx) 원본 보기(QuickLook) 경로는 손대지 않는다** — `nativelyRenderableOfficeExtensions` 집합·`QuickLookPreview` 분기는 그대로 둔다.
- 신규 기능은 별도 파일로 분리(`KordocRenderService`·`HwpxRenderState`·`HwpxRenderPreview`).
- 각 태스크는 `swift test` 전체 통과로 끝난다. **기준선(2026-07-29, `kordoc@latest` 고정 커밋 f89de58 직후 재확인): 950개 통과, 실패 0.**
- 테스트는 XCTest, `@testable import CmdMD`. kordoc 실제 서브프로세스 호출은 이 저장소 관례상 자동 테스트 대상이 아니다(순수 헬퍼만 유닛테스트, 실제 변환은 수동 스모크 — `KordocWriteServiceTests` 등 기존 패턴과 동일).
- 렌더 실패는 항상 throw로만 — 크래시 금지(기존 kordoc 서비스 3종과 동일 원칙).

---

## 파일 구조

**새로 만드는 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Services/KordocRenderService.swift` | `KordocRenderService`(actor) — `kordoc render` 호출, SVG→HTML 래핑(`wrapSVG`, 순수 static 함수), 경로+mtime 캐시 |
| `Sources/Models/HwpxRenderState.swift` | `HwpxRenderState`(loading/loaded(html:)/failed(String)) |
| `Sources/Views/HwpxRenderPreview.swift` | 상태별 화면 — 스피너 / `WKWebView`(HTML 로드) / 실패+"글로 보기로 전환" 버튼 |
| `Tests/CmdMDTests/KordocRenderServiceTests.swift` | `wrapSVG` 순수 함수 유닛테스트 |

**손대는 기존 파일** (전부 최소 변경, 기존 분기는 안 건드림)

| 파일 | 변경 |
|---|---|
| `Sources/Models/DocumentKind.swift` | `kordocRenderableExtensions = ["hwpx"]` 추가 |
| `Sources/App/AppState.swift` | `hwpxRenderStates` 딕셔너리 + `loadHwpxRender(tabID:fileURL:)` 추가, `toggleOfficeOriginalView`의 가드를 두 집합의 합집합으로 확장 |
| `Sources/Views/OfficeReaderView.swift` | `canShowOriginal` 합집합 확장, 원본 보기 분기에 hwpx 갈래 추가(기존 QuickLook 분기·편집·양식채우기 버튼은 그대로 둠) |

---

## Task 1: `KordocRenderService` — SVG 렌더 호출 + HTML 래핑 (TDD)

**목적:** kordoc `render` 명령을 호출해 SVG를 받고, 화면에 넣을 수 있는 최소 HTML로 감싸는 순수 함수를 먼저 테스트로 고정한다.

- [x] **RED**: `Tests/CmdMDTests/KordocRenderServiceTests.swift` 신설 — `KordocRenderService.wrapSVG(_:)`(가칭, static)에 대해:
  - 정상 입력(`<svg ...>...</svg>` 포함 문자열)을 넣으면 `<html>`·`<body>`로 감싸고 svg 태그가 그대로 보존되는지.
  - svg 태그가 없는 입력(방어 케이스)을 넣으면 빈 문자열이 아니라 최소한 에러를 안 내는 안전한 결과(빈 body 또는 원문 그대로 삽입 등 — 구현 시 정확한 계약 확정)를 내는지.
  - 이 시점엔 `wrapSVG`가 없어 컴파일 실패(RED) 확인.
- [x] **GREEN**: `Sources/Services/KordocRenderService.swift` 신설.
  - `enum KordocRenderError: Error { case toolNotFound, timeout, renderFailed(String) }`.
  - `actor KordocRenderService`: `private var svgCache: [String: (mtime: Date, html: String)] = [:]`.
  - `static func wrapSVG(_ svg: String) -> String` — 순수 함수, 최소 HTML 문자열 생성(`<html><body style="margin:0;background:white">` + svg + `</body></html>` 형태, 정확한 마크업은 구현 시 확정).
  - `func renderHTML(for fileURL: URL) async throws -> String`:
    1. mtime 확인 → 캐시 hit이면 즉시 반환.
    2. `KordocService.resolveNpxPath()` 실패 시 `.toolNotFound`.
    3. `Process`(`npx`, `["-y", KordocService.packageSpec, "render", fileURL.path(percentEncoded: false), "-o", tmpSVGPath, "--silent"]`) — 기존 3개 kordoc 서비스와 동일한 파이프·타임아웃(120초) 패턴.
    4. 실패(exit != 0) 시 stderr 문자열을 `.renderFailed(message)`로 throw(설계 문서 §3에서 실측한 "조판 캐시 없음…" 같은 문구가 그대로 담김 — 사용자에게 그대로 보여줘도 이해 가능한 한국어 문구임을 이미 확인).
    5. 성공 시 임시 SVG 파일 읽어 `wrapSVG(_:)` 적용 → 캐시 저장 → 반환.
    6. `defer`로 임시 파일 정리(기존 3개 서비스 관례와 동일).
- [x] `swift build`·`swift test` 전체 통과 확인(950 + 신규 `wrapSVG` 테스트 개수) — 953개 통과.
- [x] 커밋: "기능: hwpx 원본 렌더 서비스(KordocRenderService) — Task 1" (949f1be)

## Task 2: `HwpxRenderState` 모델

**목적:** 원본 렌더 상태를 담을 최소 모델. 순수 enum이라 별도 테스트 불필요(기존 `OfficeState`도 테스트 없음 — 동일 관례).

- [x] `Sources/Models/HwpxRenderState.swift` 신설:
  ```swift
  enum HwpxRenderState {
      case loading
      case loaded(html: String)
      case failed(String)
  }
  ```
- [x] `swift build` 통과 확인(신규 테스트 없음, 회귀 없음 확인만).
- [x] 커밋: "기능: HwpxRenderState 모델 — Task 2" (64417cb)

## Task 3: `DocumentKind.kordocRenderableExtensions`

- [x] `Sources/Models/DocumentKind.swift`에 `static let kordocRenderableExtensions: Set<String> = ["hwpx"]` 추가(기존 `nativelyRenderableOfficeExtensions` 주석 근처, 같은 스타일의 한국어 설명 주석 포함 — "kordoc render(SVG)로 원본 조판을 그릴 수 있는 확장자. HWPX 전용" 등).
- [x] `swift test` 전체 통과 확인(회귀 없음) — 953개.
- [x] 커밋: "기능: DocumentKind에 kordocRenderableExtensions(hwpx) 추가 — Task 3" (f374c08)

## Task 4: `AppState` 배선

**목적:** 토글 가드를 확장하고, hwpx 렌더 로딩을 트리거하는 메서드를 추가한다. **기존 MS 오피스 분기·가드는 절대 삭제하지 말고 조건만 넓힌다.**

- [x] `AppState`에 `var hwpxRenderStates: [UUID: HwpxRenderState] = [:]` 추가(다른 오피스 관련 상태 프로퍼티 근처).
- [x] `KordocRenderService`를 `AppState`의 다른 kordoc 서비스들과 같은 자리에 프로퍼티로 보관(예: `private let kordocRenderService = KordocRenderService()`).
- [x] `@MainActor func loadHwpxRender(tabID: UUID, fileURL: URL) async`:
  - `hwpxRenderStates[tabID] = .loading`
  - `do { let html = try await kordocRenderService.renderHTML(for: fileURL); hwpxRenderStates[tabID] = .loaded(html: html) }`
  - `catch`: 에러별로 한국어 메시지 분기(`.toolNotFound`→"kordoc을 찾을 수 없습니다", `.timeout`→"시간이 너무 오래 걸려 중단했습니다", `.renderFailed(msg)`→msg 그대로 + "글로 보기를 이용해 주세요" 안내 덧붙임) → `hwpxRenderStates[tabID] = .failed(...)`
- [x] `toggleOfficeOriginalView(tabID:fileURL:)`의 가드를:
  ```swift
  let ext = fileURL.pathExtension.lowercased()
  guard DocumentKind.nativelyRenderableOfficeExtensions.contains(ext)
     || DocumentKind.kordocRenderableExtensions.contains(ext) else { return }
  ```
  로 확장. 토글을 켤 때(`officeShowingOriginal.insert(tabID)` 직후) `DocumentKind.kordocRenderableExtensions.contains(ext) && hwpxRenderStates[tabID] == nil`이면 `Task { await loadHwpxRender(tabID: tabID, fileURL: fileURL) }` 트리거.
- [x] 탭 종료/문서 교체 시 `hwpxRenderStates`도 정리하는 기존 정리 로직(탭 닫을 때 `officeStates`를 지우는 자리와 같은 곳)에 한 줄 추가.
- [x] `swift test` 전체 통과 확인(회귀 없음) — 953개.
- [x] 커밋: "기능: AppState에 hwpx 원본 렌더 로딩 배선 — Task 4" (2f1e38a)

## Task 5: `HwpxRenderPreview` 뷰

- [x] `Sources/Views/HwpxRenderPreview.swift` 신설:
  ```swift
  struct HwpxRenderPreview: View {
      @Environment(AppState.self) private var appState
      let tabID: UUID
      let fileURL: URL

      var body: some View {
          switch appState.hwpxRenderStates[tabID] {
          case .loaded(let html):
              // WKWebView 래퍼(기존 마크다운 프리뷰가 쓰는 것과 같은 로드 방식 — loadHTMLString)
          case .failed(let message):
              // 기존 OfficeReaderView case .failed와 같은 모양(아이콘+메시지+버튼)
              // 버튼 액션: appState.toggleOfficeOriginalView(tabID:fileURL:) 재호출(글로 보기로 전환)
          case .loading, .none:
              // ProgressView + "원본 그리는 중…" (기존 오피스 변환 중 문구와 톤 통일)
          }
      }
  }
  ```
  - WKWebView 래퍼는 기존 저장소에 이미 있는 `NSViewRepresentable` 패턴(마크다운 프리뷰가 쓰는 것)을 재사용하거나, 없으면 최소한으로 신설(loadHTMLString만 하는 아주 얇은 래퍼 — 새 의존성 없음, WebKit은 시스템 프레임워크).
- [x] `swift build` 통과 확인.
- [x] 커밋: "기능: HwpxRenderPreview 뷰 — Task 5" (99823d3)

## Task 6: `OfficeReaderView` 배선

**목적:** 기존 토글 버튼·QuickLook 분기를 그대로 두고 hwpx 갈래만 추가한다.

- [x] `canShowOriginal` 계산 프로퍼티를:
  ```swift
  private var canShowOriginal: Bool {
      let ext = fileURL.pathExtension.lowercased()
      return DocumentKind.nativelyRenderableOfficeExtensions.contains(ext)
          || DocumentKind.kordocRenderableExtensions.contains(ext)
  }
  ```
  로 확장.
- [x] 원본 보기 분기(`else if canShowOriginal && appState.officeShowingOriginal.contains(tabID)`) 안에서 확장자로 갈라짐:
  ```swift
  if DocumentKind.nativelyRenderableOfficeExtensions.contains(fileURL.pathExtension.lowercased()) {
      QuickLookPreview(url: fileURL)
  } else {
      HwpxRenderPreview(tabID: tabID, fileURL: fileURL)
  }
  ```
- [x] 토글 버튼 라벨·위치는 변경하지 않는다(기존 "원본 보기"/"글로 보기" 문구 그대로 — hwpx도 같은 버튼을 씀).
- [x] `swift test` 전체 통과 확인(회귀 없음) — 953개, MS 오피스 원본 보기 코드 경로 diff 확인.
- [x] 커밋: "기능: OfficeReaderView에 hwpx 원본 보기 배선 — Task 6" (b60e5a5)

## Task 7: 전체 회귀 확인 + 재패키징·설치 + 수동 스모크 안내

- [x] `swift test` 전체 재실행 — 기준선(950) 대비 정확히 +3(Task 1 테스트) 확인, 실패 0 — 953개 통과.
- [x] `./scripts/package_app.sh` 재패키징 → `/Applications` 교체 설치 완료(ad-hoc 로컬 인증서 서명 유효 확인).
- [x] `CmdMD-fork_prd.md` §10 격차 5번 항목에 "hwpx 원본 보기 완료(2026-07-29), hwp는 도구 한계로 계속 보류" 갱신 완료.
- [ ] **레고님 필수 수동 스모크(설계 문서 §8 그대로)** — 실제 한글 프로그램에서 저장한 진짜 `.hwpx` 파일로:
  1. "원본 보기" 버튼이 뜨는지(hwp 파일은 안 뜨는지도 같이 확인).
  2. 눌렀을 때 캐시 기반으로 바로 렌더되는지(로딩이 몇 초 안에 끝나는지).
  3. 글꼴·표·문단이 실제 한컴 화면과 비슷하게 보이는지.
  4. 여러 쪽 문서에서 스크롤이 되는지.
  5. "글로 보기"로 되돌아가는지.
  6. (있다면) kordoc으로 이미 생성/패치한 hwpx처럼 조판 캐시가 없는 파일을 열었을 때 실패 메시지+전환 버튼이 뜨는지, 앱이 멈추지 않는지.
- [ ] 이 스모크가 전부 통과해야 이번 조각을 "완료"로 표기한다 — 자동 테스트만으로는 이 기능의 실사용 가치를 확정할 수 없음(설계 문서 §8 핵심 미확인 지점).
