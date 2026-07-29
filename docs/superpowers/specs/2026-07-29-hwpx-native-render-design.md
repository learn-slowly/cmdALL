# 한글(.hwpx) 원본 그대로 보기 — 재검토 (설계)

- 날짜: 2026-07-29
- 상태: 설계 승인 대기
- 상위 맥락: `.gjc/context/docufinder-parity-20260727T021555Z.md`(Docufinder 기능 격차 7개) 5번 항목 — 2026-07-27 당시 "kordoc에 SVG·HTML 렌더 기능이 없어 불가능"으로 보류됨.
- 근거 원문: `CmdMD-fork_prd.md` §10 격차 5번 — "한글(HWP/HWPX)·워드·엑셀 파일을 kordoc→마크다운 변환 없이 원본 모양 그대로 보기. MS 오피스는 완료, HWP류는 도구 한계로 보류."
- 재검토 계기: 2026-07-29 kordoc 버전 확인 중 `kordoc render` 명령(HWPX → SVG, v3.10부터 존재, v4까지 계속 보강)을 뒤늦게 발견 — 지난 조사가 이 컴퓨터의 npx 캐시가 옛날 버전(3.1.1)을 계속 돌려주는 문제 때문에 최신 기능을 놓쳤을 가능성이 있음(같은 날 별도로 `kordoc@latest` 고정 조치 완료, 커밋 f89de58).

---

## 쉬운 말 요약 (레고용)

- **지금**: 한글 파일(.hwp·.hwpx)을 열면 항상 "글로 보기"(kordoc이 뽑아낸 마크다운 텍스트)만 보인다. 워드·엑셀은 "원본 보기" 버튼으로 진짜 조판 그대로 볼 수 있는데, 한글 파일은 그 버튼 자체가 없다.
- **바뀐 뒤(이번 설계)**: `.hwpx`(요즘 한글 파일, 확장자가 hwpx인 것) 파일에도 "원본 보기" 버튼이 새로 생긴다. 누르면 kordoc이 그려주는 원본 모양 그대로(그림처럼, 여러 쪽이면 위아래로 이어서) 보여준다.
- **여전히 안 되는 것**: `.hwp`(옛날 방식, 확장자가 hwp인 것 — 한컴이 2020년 이전에 주로 쓰던 저장 방식)는 이번에도 안 된다. kordoc에 이 형식을 그림으로 그리는 기능 자체가 없다(확인 완료). hwp 파일은 지금처럼 "글로 보기"만 가능하고, 버튼 자체가 안 보인다.
- **실패했을 때**: 드물게 파일 구조가 특이해서 원본 그리기가 실패하면, 에러 문구와 함께 "글로 보기로 전환" 버튼을 보여준다. 앱이 멈추거나 깨지지 않는다.
- **이번 산출물**: 코드는 안 건드리고, 설계 문서와 계획 문서만 작성한다. 실제 화면이 바뀌는 건 레고가 이 문서들을 보고 승인한 다음이다.

---

## 1. 목적 (왜)

지난주(2026-07-27) Docufinder 기능 격차 7개 중 5번(원본 그대로 보기)을 "도구 한계로 불가능"이라 결론짓고 MS 오피스만 부분 완료했다. 그런데 오늘(2026-07-29) kordoc 최신 버전을 확인하는 과정에서 그 결론의 근거였던 "SVG·HTML 렌더 출력이 없다"는 사실이 더 이상 맞지 않음을 발견했다 — kordoc이 `render` 명령으로 HWPX를 SVG로 그리는 기능을 이미 갖추고 있었다(v3.10부터, 이후 v3.17까지 글꼴·다구역 문서·가로 문서 등 충실도를 계속 보강). 보류했던 결정을 다시 열어 `.hwpx`만이라도 구현하는 것이 이번 설계의 목적이다.

## 2. 무엇을 바꾸나 (범위)

- 대상: `.hwpx` 파일 한정. `.hwp`(바이너리 구버전)는 대상 아님 — 아래 §3 실측 참고.
- `OfficeReaderView`의 기존 "원본 보기 ⇄ 글로 보기" 토글(MS 오피스 전용, `AppState.officeShowingOriginal`)을 `.hwpx`까지 확장한다. 다만 실제로 그리는 방식은 다르다(MS 오피스=macOS QuickLook, hwpx=kordoc SVG 렌더 신설).
- 편집 모드(hwpx 패치 저장)나 양식 채우기 등 기존 기능은 손대지 않는다 — "원본 보기"는 어디까지나 읽기 전용 미리보기 한 가지가 늘어나는 것뿐이다.

## 3. 실측 — 오늘 직접 확인한 것

- **kordoc 버전 확인**: `npm view kordoc version` → `4.2.9`(2026-07-26 배포). 반면 이 컴퓨터에서 버전 지정 없이 `npx kordoc`을 부르면 캐시 때문에 `3.1.1`(몇 달 전 버전)이 잡혔다 — `npx kordoc@latest`로 지정해야 진짜 최신이 잡힘. **이 문제는 이미 별도로 고쳤다**(같은 날 커밋 `f89de58` — `KordocService.packageSpec = "kordoc@latest"`를 4개 호출부 전부에 적용, 실제 hwp 샘플 파일로 변환 재확인 완료).
- **`kordoc render` 명령 존재 확인**: `npx kordoc@latest render --help` →
  ```
  Usage: kordoc render [options] <file>
  레이아웃 보존 렌더 — 한컴 저장 HWPX의 조판 캐시를 SVG로 (전체 페이지 세로 스택)
  Options:
    -o, --output <path>   출력 SVG 경로
    --highlight <terms>   검색어 형광펜 (쉼표 구분)
    --reflow               조판 캐시 없는 HWPX도 순수 TS 조판으로 렌더
    --reflow-mode <mode>   reflow 줄바꿈 모드
  ```
  **`.hwpx` 전용**이고(명령 설명 자체가 "HWPX의 조판 캐시"라고 명시), `.hwp`는 언급조차 없다. kordoc 함수 이름도 `renderHwpxToSvg`로 HWPX 전용임이 API 문서에도 명시돼 있다.
- **실제 렌더 스파이크(제 컴퓨터에서 직접 실행)**:
  1. 테스트용 마크다운 → `kordoc generate`로 hwpx 생성(92KB) → 성공.
  2. 그 hwpx를 `kordoc render --reflow`로 SVG 변환 → **0.64초, 8.5KB SVG 생성 성공**. 결과 SVG는 진짜 페이지 크기(595×842pt, A4)·글꼴 이름·표 2개·텍스트 16개가 제대로 담긴 유효한 SVG였다(직접 앞부분 확인).
  3. **같은 파일을 `--reflow` 없이 렌더 시도** → 실패, 에러 메시지: `조판 캐시(linesegarray) 없음 — 한컴에서 저장한 HWPX만 렌더 가능 (reflow 옵션으로 합성 렌더 가능)`. **exit code 1, 깨끗한 실패**(크래시·행 없음).
  - 이 3번 결과가 중요하다 — kordoc이 자체 생성한 파일(조판 캐시 없음)은 `--reflow` 없이는 실패하지만, **레고님이 한컴(한글 프로그램)으로 직접 저장한 진짜 hwpx 파일은 조판 캐시가 있어서 `--reflow` 없이 바로 렌더될 것으로 예상**된다(kordoc 문서가 "한컴 저장본은 캐시 재생 그대로" 라고 명시). 다만 **이 컴퓨터엔 레고님이 실제로 한컴에서 저장한 hwpx 샘플이 없어 이 경로는 아직 실제로 확인 못 했다** — §8 검증 계획에 필수 항목으로 넣는다.
- **기존 코드 구조**: `OfficeReaderView.swift`(§11~15)의 `canShowOriginal`이 `DocumentKind.nativelyRenderableOfficeExtensions`(`["doc","docx","xls","xlsx"]`)만 검사하고, 토글이 켜지면 `QuickLookPreview(url:)`를 보여준다. `AppState.toggleOfficeOriginalView`(`AppState.swift:518`)도 같은 집합으로 가드한다. hwp/hwpx는 이 집합에 없어 버튼 자체가 안 뜬다.
- 참고 서비스 패턴: `KordocService`(actor, `resolveNpxPath()`+`packageSpec` 공용)·`KordocWriteService`·`KordocFillService`가 전부 같은 모양(Process로 npx 호출, 120초 타임아웃, 임시파일 경유, 실패는 throw만·크래시 없음)을 따른다. 새 서비스도 이 모양을 그대로 따른다.
- kordoc 관련 서비스는 실제 npx 서브프로세스 호출까지는 자동 테스트하지 않는 게 이 저장소 관례다(`KordocWriteServiceTests.swift` 확인 — 순수 헬퍼 함수만 유닛테스트, 실제 변환은 수동 스모크). 새 서비스도 같은 관례를 따른다.

## 4. 대안 비교

### 4-1. SVG를 화면에 어떻게 보여줄까

| 방법 | 장점 | 단점 | 채택 |
|---|---|---|---|
| WKWebView에 `loadHTMLString`로 SVG를 감싼 HTML 주입 | 이미 앱 전체가 WKWebView 기반 미리보기(마크다운 등)를 쓰고 있어 패턴이 같음. 스크롤·트랙패드 확대가 공짜로 됨. | 없음(단점 미미) | ✅ |
| `NSImageView`/`SVGKit` 등 네이티브 렌더링 | — | SVG 네이티브 렌더 라이브러리가 없음(새 의존성 필요) — "새 패키지 의존성 0" 원칙 위배 | ❌ |
| WKWebView `loadFileURL`로 svg 파일 직접 로드 | 코드 더 짧음 | 파일 시스템 접근 권한·상대경로 baseURL 설정이 얽혀 기존 마크다운 프리뷰 패턴과 다르게 감 | ❌(HTML 문자열 주입이 기존 패턴과 더 일관) |

**결론**: kordoc이 출력한 `<svg>...</svg>` 태그를 그대로 최소 HTML(`<html><body style="margin:0">...svg...</body></html>`)에 감싸 `WKWebView.loadHTMLString`으로 표시. 페이지가 여러 장이면 kordoc이 이미 세로로 이어붙여 한 SVG로 주므로 그대로 스크롤하면 됨(별도 페이지 넘김 UI 불필요).

### 4-2. 캐시 없는 파일(--reflow 필요)을 자동으로 처리할까

| 방법 | 장점 | 단점 | 채택 |
|---|---|---|---|
| 실패 시 자동으로 `--reflow` 재시도 | 사용자가 못 보는 경우가 줄어듦 | reflow는 "합성" 렌더라 실제 한컴 조판과 다를 수 있음 — 실패 원인·정확도 구분이 흐려짐. 이번 대상(레고님이 한컴으로 저장한 실제 파일)은 대부분 캐시가 있어 필요성이 낮음. | ❌(이번엔 안 함) |
| 실패하면 그대로 에러 표시 + "글로 보기로 전환" 버튼 | 기존 `OfficeReaderView` 실패 상태 UX(§79-95, `case .failed`)와 완전히 같은 패턴 재사용. 정직한 실패. | 드문 경우지만 안 보이는 케이스가 생김 | ✅ |

**결론**: `--reflow` 없이 시도만 한다. 실패하면 명확한 안내 + 글로 보기 전환 버튼. reflow 자동 폴백은 실사용에서 필요하다고 확인되면 후속 조각으로 검토(§7).

## 5. 설계 상세

### 5.1 새 서비스 — `KordocRenderService`

```swift
actor KordocRenderService {
    private let timeout: TimeInterval = 120
    private var svgCache: [String: (mtime: Date, html: String)] = [:]  // 키=경로

    func renderHTML(for fileURL: URL) async throws -> String
    // 내부: resolveNpxPath (KordocService 재사용) → Process(npx, ["-y", KordocService.packageSpec,
    //   "render", fileURL.path, "-o", tmpSVGPath, "--silent"]) → 120초 타임아웃 →
    //   실패 시 stderr 문구를 그대로 KordocRenderError.renderFailed(String)로 throw
    //   (에러 문구가 이미 한국어라 그대로 사용자에게 보여줘도 됨 — §3 실측한 문구 예시 참고) →
    //   성공 시 tmp SVG 파일 읽어 `<svg ...>...</svg>` 추출 → 최소 HTML 래핑 → mtime 캐시
}

enum KordocRenderError: Error {
    case toolNotFound
    case timeout
    case renderFailed(String)  // kordoc stderr 메시지 그대로
}
```

- `KordocService.resolveNpxPath()`·`KordocService.packageSpec`을 그대로 재사용(중복 없음).
- HTML 래핑은 순수 함수로 분리(`KordocRenderService.wrapSVG(_ svg: String) -> String` 같은 정적 함수) — 유닛테스트 대상.
- 캐시 키는 파일 경로+mtime(기존 `KordocService.markdownCache`와 동일 패턴) — 파일이 바뀌면 재렌더.

### 5.2 상태 모델 — `HwpxRenderState`(신규, `Sources/Models/HwpxRenderState.swift`)

```swift
enum HwpxRenderState {
    case loading
    case loaded(html: String)
    case failed(String)
}
```

`AppState.officeStates`(기존 `OfficeState`)와 같은 모양이지만 별개 딕셔너리로 둔다(§5.3) — 오피스 변환 상태와 원본 렌더 상태는 독립적으로 로딩/실패할 수 있어서 섞으면 안 됨.

### 5.3 `AppState` 변경

- 신규: `var hwpxRenderStates: [UUID: HwpxRenderState] = [:]`
- 신규: `@MainActor func loadHwpxRender(tabID: UUID, fileURL: URL) async` — `hwpxRenderStates[tabID] = .loading` → `KordocRenderService.renderHTML(for:)` 호출 → 성공 시 `.loaded(html:)`, 실패 시 `.failed(한국어 메시지)`.
- 기존 `toggleOfficeOriginalView(tabID:fileURL:)`의 가드를 `DocumentKind.nativelyRenderableOfficeExtensions.contains(...) || DocumentKind.kordocRenderableExtensions.contains(...)`로 확장. hwpx이고 처음 켜는 거면(`hwpxRenderStates[tabID] == nil`) `loadHwpxRender` 트리거.
- 편집 모드 진입 시(`beginOfficeEdit`) 기존처럼 `officeShowingOriginal.remove(tabID)`도 하되, `hwpxRenderStates[tabID]`는 지우지 않는다(재진입 시 캐시 재사용 — mtime 안 바뀌었으면 재렌더 불필요, 서비스 캐시가 처리).

### 5.4 `DocumentKind` 변경

```swift
/// kordoc render(SVG)로 원본 조판을 그릴 수 있는 확장자. HWPX 전용 —
/// kordoc에 HWP(구버전 바이너리) 렌더 기능 자체가 없음(실측 확인, 2026-07-29).
static let kordocRenderableExtensions: Set<String> = ["hwpx"]
```

### 5.5 화면 — `OfficeReaderView` + 신규 `HwpxRenderPreview`

- `canShowOriginal` 계산 프로퍼티를 두 집합의 합집합으로 확장.
- 토글 버튼 라벨/동작은 기존 그대로("원본 보기"/"글로 보기") — 사용자 입장에서 MS 오피스든 hwpx든 버튼 위치·모양이 똑같다.
- 분기 추가: `else if canShowOriginal && appState.officeShowingOriginal.contains(tabID)` 블록 안에서, 확장자가 `nativelyRenderableOfficeExtensions`면 기존 `QuickLookPreview(url:)`, `kordocRenderableExtensions`(hwpx)면 신규 `HwpxRenderPreview(tabID:)`.
- 신규 `HwpxRenderPreview`(뷰): `appState.hwpxRenderStates[tabID]`를 보고 `.loading`→스피너(기존 오피스 변환 중 문구와 톤 통일: "원본 그리는 중…"), `.loaded(html)`→`WKWebView`(loadHTMLString), `.failed(message)`→기존 `OfficeReaderView`의 실패 상태와 같은 모양(아이콘+메시지+"글로 보기로 전환" 버튼, 버튼은 `appState.toggleOfficeOriginalView` 재호출).

## 6. 파일 구조 (구현 시 예정)

**새로 만드는 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Services/KordocRenderService.swift` | `KordocRenderService`(actor) — kordoc render 호출·SVG→HTML 래핑·경로+mtime 캐시 |
| `Sources/Models/HwpxRenderState.swift` | `HwpxRenderState`(loading/loaded/failed) |
| `Sources/Views/HwpxRenderPreview.swift` | 상태별 화면(스피너/WKWebView/실패+전환버튼) |
| `Tests/CmdMDTests/KordocRenderServiceTests.swift` | `wrapSVG` 등 순수 헬퍼 유닛테스트(실제 npx 호출은 관례상 수동 스모크) |

**손대는 기존 파일**

| 파일 | 변경 |
|---|---|
| `Sources/Models/DocumentKind.swift` | `kordocRenderableExtensions` 추가 |
| `Sources/App/AppState.swift` | `hwpxRenderStates` 딕셔너리, `loadHwpxRender`, `toggleOfficeOriginalView` 가드 확장(기존 MS 오피스 분기는 그대로 둠) |
| `Sources/Views/OfficeReaderView.swift` | `canShowOriginal` 합집합 확장, 원본 보기 분기에 hwpx 갈래 추가(QuickLook 분기는 손대지 않음) |

## 7. 이번에 하지 않을 것

- `.hwp`(구버전 바이너리) 원본 보기 — kordoc에 기능 자체가 없어 불가능 확정(재확인 완료).
- `--reflow` 자동 폴백(§4-2) — 처음엔 안 하고, 실사용 중 캐시 없는 파일을 자주 만난다는 게 확인되면 후속으로.
- 검색어 형광펜(`--highlight`) 연동 — kordoc이 지원하지만 이번 범위 밖.
- SVG 안에서 확대/축소 전용 UI(PDF 리더의 확대 버튼류) — WKWebView 기본 트랙패드 확대로 충분한지 먼저 보고 필요하면 후속.
- 실제 Swift 코드 구현 — 이 문서와 계획 문서 작성까지만. 코드는 사용자 승인 후 별도 착수.

## 8. 검증 계획

- 신규 유닛테스트: `KordocRenderServiceTests`(SVG→HTML 래핑 순수 함수 — 빈 문자열·`<svg>` 태그 없는 입력 등 방어 케이스, 정상 입력이 올바른 HTML 구조로 감싸지는지).
- 기존 `swift test` 전체 그린 유지(계획 문서에 착수 시점 기준선 950개 명시, 이번엔 순수 헬퍼만 늘어남).
- **필수 수동 스모크(자동 불가·이번 설계의 핵심 미확인 지점)**: 레고님이 실제로 한글 프로그램에서 저장한 진짜 `.hwpx` 파일로 "원본 보기" 버튼을 눌러 ①조판 캐시가 있어 `--reflow` 없이 바로 렌더되는지 ②글꼴·표·문단 정렬이 실제 한컴 화면과 비슷하게 보이는지 ③여러 쪽 문서에서 스크롤이 되는지 ④"글로 보기"로 되돌아가는지 ⑤캐시 없는 파일(예: 이미 kordoc으로 생성/패치한 결과물)을 열었을 때 실패 메시지+전환 버튼이 뜨는지. **이 항목이 통과해야 이번 기능이 실사용 가치가 있다고 확정할 수 있다** — §3에서 이미 언급했듯 이 컴퓨터엔 진짜 한컴 저장본 hwpx 샘플이 없어 구현 직후 레고님 확인이 특히 중요하다.
