# 못 여는 파일 → 애플 미리보기 (조각 A) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 아는 형식이 아닌 파일도 목록에 보이고, 누르면 애플 미리보기로 열리며, 스페이스바로 훑어볼 수 있게 한다. 함께 글자 파일 색인 확장과 숨김 파일 표시 옵션을 넣는다.

**Architecture:** 순수 판정 헬퍼(`QuickLookRouting`)가 "이 파일을 글로 열까, 미리보기로 넘길까"를 단독으로 결정하고, `DocumentKind`·목록 필터·검색 색인이 모두 그 하나를 재사용한다. 미리보기는 macOS 내장 `QLPreviewView`를 `NSViewRepresentable`로 감싼다. 신규 코드는 전부 새 파일로 두고 기존 파일은 최소한만 손댄다(업스트림 머지 용이성 — 프로젝트 관례).

**Tech Stack:** Swift 5.9+ / SwiftUI / AppKit, `Quartz`(QuickLook — macOS 내장), `UniformTypeIdentifiers`(macOS 내장), XCTest.

## Global Constraints

- **새 패키지 의존성 0.** `Quartz`·`UniformTypeIdentifiers`는 macOS 기본 내장이다. `Package.swift`에 의존성을 추가하지 않는다.
- **macOS 14+ / Swift 5.9+.** 그 아래 API는 쓰지 않는다.
- 코드 주석·커밋 메시지는 **한국어**로 쓴다.
- 글에서 '박다/박는다/박았다' 표현은 쓰지 않는다.
- **원본 파일 불변.** 이 작업의 어떤 경로도 사용자 파일을 쓰거나 지우지 않는다.
- **비샌드박스 유지.**
- 신규 기능은 **별도 파일**로 분리한다.
- 각 태스크는 `swift test` 전체 통과로 끝난다. **현재 기준선 814개**(XCTest 796 + Swift Testing 18). 기존 테스트를 깨뜨리지 않는다.
- 테스트는 XCTest, `@testable import CmdMD`. `AppState`를 쓰는 테스트는 반드시 `AppState(dataDirectory: TempDataDirectory.make())`로 격리한다.

---

## 파일 구조

**새로 만드는 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Services/QuickLookRouting.swift` | 확장자 → "글로 열기 / 미리보기" 판정(순수 + 캐시). 이 판정의 **단일 진실 원천** |
| `Sources/Views/QuickLookReaderView.swift` | 미리보기 탭 화면 — `QLPreviewView` 감싸기 + 위쪽 버튼 줄 + 기본 앱 이름 조회 |
| `Sources/Views/QuickLookQuickPanel.swift` | 스페이스바 빠른 보기 오버레이 |
| `Tests/CmdMDTests/QuickLookRoutingTests.swift` | 판정 규칙 |
| `Tests/CmdMDTests/FileListingVisibilityTests.swift` | 목록 노출·숨김 파일 |
| `Tests/CmdMDTests/AppQuickLookTests.swift` | "글로 열기" 전환·스페이스 키 라우팅 |
| `Tests/CmdMDTests/ContentExtractorTextTests.swift` | 글자 파일 색인 확장 |

**손대는 기존 파일** (전부 최소 변경)

| 파일 | 변경 |
|---|---|
| `Sources/Models/DocumentKind.swift` | 갈래 `quickLook` 추가, `init(from:)` 판정 순서, `sortRank` |
| `Sources/Models/Settings.swift` | `showHiddenFiles` 추가 |
| `Sources/App/AppState.swift` | `isListableInFileTree` 개방, `buildFileTree` 숨김 인자, `reopenAsText`, 스페이스 키 라우팅·상태 |
| `Sources/Services/LibraryListing.swift` | `entries(of:showHidden:)` |
| `Sources/Services/ContentExtractor.swift` | 글자 파일 본문 추출 + 5MB 상한 |
| `Sources/Services/SearchIndex.swift` | 추출 규칙 판 번호 저장·조회 |
| `Sources/Views/MainEditorView.swift` | `quickLook` 갈래 분기 |
| `Sources/Views/ContentView.swift` | 빠른 보기 오버레이 |
| `Sources/Views/SettingsView.swift` | 숨김 파일 스위치 |
| `Sources/App/CmdMDApp.swift` | 키 모니터에 빠른 보기 라우팅 선행 |

---

## Task 1: 갈림길 판정 규칙

**Files:**
- Create: `Sources/Services/QuickLookRouting.swift`
- Modify: `Sources/Models/DocumentKind.swift`
- Test: `Tests/CmdMDTests/QuickLookRoutingTests.swift`

**Interfaces:**
- Consumes: (없음 — 첫 태스크)
- Produces:
  - `QuickLookRouting.opensAsText(extension ext: String) -> Bool`
  - `DocumentKind.quickLook` (enum case, rawValue `"quickLook"`)
  - `DocumentKind.init(from url: URL)` 동작 변경
  - `DocumentKind.sortRank` 에 `quickLook = 5`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/CmdMDTests/QuickLookRoutingTests.swift` 를 만든다:

```swift
import XCTest
@testable import CmdMD

/// 확장자 → "글로 열기 / 애플 미리보기" 판정(스펙 §3).
final class QuickLookRoutingTests: XCTestCase {

    func test맥이글자라답하는확장자는글로연다() {
        for ext in ["csv", "json", "swift", "log", "yml", "xml", "html", "py", "sh", "md", "txt"] {
            XCTAssertTrue(QuickLookRouting.opensAsText(extension: ext),
                          "\(ext)는 글로 열어야 한다")
        }
    }

    func test글자가아닌확장자는미리보기로간다() {
        for ext in ["pptx", "ppt", "key", "numbers", "pages", "zip", "psd", "ai", "epub", "ttf", "dmg", "app"] {
            XCTAssertFalse(QuickLookRouting.opensAsText(extension: ext),
                           "\(ext)는 미리보기로 가야 한다")
        }
    }

    func testRtf는글자라답해도미리보기로간다() {
        // 맥은 rtf를 public.rtf(텍스트 계열)로 답하지만 편집기로 열면 서식 부호가 보인다.
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: "rtf"))
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: "rtfd"))
    }

    func test맥이모르는흔한글자확장자는빠른경로가구제한다() {
        // .conf/.ini/.toml은 맥이 dyn.…으로 답해 '글자 아님'이 된다(실측).
        // 빠른 경로 목록이 이를 구제한다.
        for ext in ["conf", "ini", "toml"] {
            XCTAssertTrue(QuickLookRouting.opensAsText(extension: ext))
        }
    }

    func test확장자없으면미리보기로간다() {
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: ""))
    }

    func test대소문자를무시한다() {
        XCTAssertTrue(QuickLookRouting.opensAsText(extension: "JSON"))
        XCTAssertFalse(QuickLookRouting.opensAsText(extension: "PPTX"))
    }

    func test아는여섯종류는quickLook으로새지않는다() {
        // 판정 순서 안전장치 — 기존 갈래가 새 갈래로 새면 회귀다.
        let known = ["md", "markdown", "txt", "png", "jpg", "heic", "gif", "pdf",
                     "hwp", "hwpx", "docx", "xlsx", "mp3", "wav", "mp4", "mov"]
        for ext in known {
            let url = URL(fileURLWithPath: "/tmp/파일.\(ext)")
            XCTAssertNotEqual(DocumentKind(from: url), .quickLook,
                              "\(ext)는 기존 갈래를 유지해야 한다")
        }
    }

    func test모르는형식은quickLook갈래가된다() {
        for ext in ["pptx", "zip", "psd", "key", "epub"] {
            let url = URL(fileURLWithPath: "/tmp/파일.\(ext)")
            XCTAssertEqual(DocumentKind(from: url), .quickLook)
        }
    }

    func test글자파일은markdown갈래를유지한다() {
        for ext in ["json", "swift", "csv", "yml"] {
            let url = URL(fileURLWithPath: "/tmp/파일.\(ext)")
            XCTAssertEqual(DocumentKind(from: url), .markdown)
        }
    }

    func testQuickLook정렬순위는맨끝이다() {
        XCTAssertGreaterThan(DocumentKind.quickLook.sortRank, DocumentKind.media.sortRank)
    }
}
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `swift test --filter QuickLookRoutingTests`
Expected: 컴파일 실패 — `cannot find 'QuickLookRouting' in scope`, `type 'DocumentKind' has no member 'quickLook'`

- [ ] **Step 3: 판정 헬퍼를 만든다**

`Sources/Services/QuickLookRouting.swift`:

```swift
import Foundation
import UniformTypeIdentifiers

/// 확장자 → "편집기로 글처럼 열까 / 애플 미리보기로 넘길까" 판정.
/// DocumentKind·목록 필터·검색 색인이 모두 이 하나를 재사용한다(단일 진실 원천).
enum QuickLookRouting {

    /// 맥에 묻지 않고 바로 "글자"로 판정하는 빠른 경로.
    /// 두 몫을 한다 — (1) 목록 정렬처럼 항목마다 불리는 곳의 조회 비용 제거
    /// (2) 맥이 `dyn.…`으로 답해 '글자 아님'이 되는 흔한 설정 파일 구제(실측).
    static let textFastPath: Set<String> = [
        "md", "markdown", "mdown", "txt", "text",
        "csv", "tsv", "json", "yml", "yaml", "toml", "ini", "conf", "cfg",
        "xml", "html", "htm", "css", "js", "ts", "jsx", "tsx",
        "py", "sh", "zsh", "bash", "rb", "go", "rs", "java", "kt",
        "swift", "c", "h", "cpp", "hpp", "m", "mm",
        "log", "srt", "vtt", "tex", "bib", "env", "gitignore", "mdx"
    ]

    /// 맥이 "글자"라 답해도 편집기로 열지 않을 예외.
    /// rtf/rtfd는 public.rtf(텍스트 계열)지만 편집기에는 서식 부호가 그대로 보인다.
    static let textExceptions: Set<String> = ["rtf", "rtfd"]

    /// 맥에 물어본 결과 캐시 — 백그라운드 트리 스캔에서도 불리므로 잠금으로 보호한다.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    /// true = 편집기로 연다(기존 동작). false = 애플 미리보기로 넘긴다.
    static func opensAsText(extension ext: String) -> Bool {
        let key = ext.lowercased()
        if key.isEmpty { return false }
        if textExceptions.contains(key) { return false }
        if textFastPath.contains(key) { return true }

        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let answer = UTType(filenameExtension: key)?.conforms(to: .text) ?? false

        cacheLock.lock()
        cache[key] = answer
        cacheLock.unlock()
        return answer
    }

    /// URL 편의 오버로드.
    static func opensAsText(_ url: URL) -> Bool {
        opensAsText(extension: url.pathExtension)
    }
}
```

- [ ] **Step 4: `DocumentKind`에 갈래를 더한다**

`Sources/Models/DocumentKind.swift` 에서 enum 본체에 `case quickLook` 을 더한다:

```swift
enum DocumentKind: String, Codable {
    case markdown
    case image
    case pdf
    case office
    case media
    /// 우리가 모르는 형식 — 애플 미리보기(QuickLook)로 보여준다. 읽기 전용.
    case quickLook
}
```

`sortRank` 에 갈래를 더한다(맨 끝):

```swift
    var sortRank: Int {
        switch self {
        case .markdown:  return 0
        case .office:    return 1
        case .pdf:       return 2
        case .image:     return 3
        case .media:     return 4
        case .quickLook: return 5
        }
    }
```

`init(from:)` 의 마지막 `else` 를 판정으로 바꾼다. **앞의 네 갈래는 손대지 않는다** — 순서가 안전장치다:

```swift
    /// 확장자(대소문자 무시): 이미지 → PDF → 오피스 → 미디어 → 글자 → 미리보기.
    /// 앞 네 갈래를 먼저 확정해야 기존 종류가 새 갈래로 새지 않는다(스펙 §3).
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.imageExtensions.contains(ext) {
            self = .image
        } else if DocumentKind.pdfExtensions.contains(ext) {
            self = .pdf
        } else if DocumentKind.officeExtensions.contains(ext) {
            self = .office
        } else if DocumentKind.mediaExtensions.contains(ext) {
            self = .media
        } else if QuickLookRouting.opensAsText(extension: ext) {
            self = .markdown
        } else {
            self = .quickLook
        }
    }
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `swift test --filter QuickLookRoutingTests`
Expected: PASS (10개)

- [ ] **Step 6: 전체 테스트로 회귀를 확인한다**

Run: `swift test 2>&1 | tail -20`
Expected: 실패 0. `DocumentKind`를 `switch`로 다루는 곳이 있으면 컴파일 오류가 나므로 **여기서 전부 드러난다** — `case .quickLook` 분기를 더해 고친다(대부분 기존 `default`가 받는다).

- [ ] **Step 7: 커밋**

```bash
git add Sources/Services/QuickLookRouting.swift Sources/Models/DocumentKind.swift Tests/CmdMDTests/QuickLookRoutingTests.swift
git commit -m "미리보기(1/7): 갈림길 판정 규칙 — 맥에 물어 글/미리보기를 가른다"
```

---

## Task 2: 목록 열기 + 숨김 파일 옵션

**Files:**
- Modify: `Sources/App/AppState.swift:1715-1722` (`isListableInFileTree`), `Sources/App/AppState.swift:1729-1736` (`buildFileTree`)
- Modify: `Sources/Services/LibraryListing.swift:15-20`
- Modify: `Sources/Models/Settings.swift`
- Modify: `Sources/Views/SettingsView.swift`
- Test: `Tests/CmdMDTests/FileListingVisibilityTests.swift`

**Interfaces:**
- Consumes: Task 1의 `DocumentKind.quickLook`
- Produces:
  - `AppState.isListableInFileTree(_ url: URL) -> Bool` (이제 항상 `true`이나 시그니처 유지)
  - `AppState.buildFileTree(at:expanded:showHidden:depth:)` — `showHidden: Bool = false`
  - `LibraryListing.entries(of folder: URL, showHidden: Bool = false) -> [FileTreeItem]`
  - `AppSettings.showHiddenFiles: Bool`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/CmdMDTests/FileListingVisibilityTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 목록 노출 규칙 — 모든 파일 표시(스펙 §3.5) + 숨김 파일 옵션.
final class FileListingVisibilityTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("목록테스트-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["보고서.md", "발표.pptx", "묶음.zip", "설정.json", ".숨김파일", ".gitignore"] {
            try "내용".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    private func names(_ items: [FileTreeItem]) -> Set<String> {
        Set(items.map { $0.url.lastPathComponent })
    }

    func test모르는형식도목록에보인다() {
        let got = names(LibraryListing.entries(of: dir))
        XCTAssertTrue(got.contains("발표.pptx"), "pptx가 목록에 보여야 한다")
        XCTAssertTrue(got.contains("묶음.zip"), "zip이 목록에 보여야 한다")
        XCTAssertTrue(got.contains("설정.json"))
        XCTAssertTrue(got.contains("보고서.md"), "기존 형식은 그대로 보여야 한다")
    }

    func test숨김파일은기본으로안보인다() {
        let got = names(LibraryListing.entries(of: dir))
        XCTAssertFalse(got.contains(".숨김파일"))
        XCTAssertFalse(got.contains(".gitignore"))
    }

    func test숨김파일옵션을켜면보인다() {
        let got = names(LibraryListing.entries(of: dir, showHidden: true))
        XCTAssertTrue(got.contains(".숨김파일"))
        XCTAssertTrue(got.contains(".gitignore"))
        XCTAssertTrue(got.contains("보고서.md"), "켜도 일반 파일은 그대로 보인다")
    }

    func test트리도같은규칙을따른다() {
        let 기본 = names(AppState.buildFileTree(at: dir, expanded: []))
        XCTAssertTrue(기본.contains("발표.pptx"))
        XCTAssertFalse(기본.contains(".gitignore"))

        let 숨김켬 = names(AppState.buildFileTree(at: dir, expanded: [], showHidden: true))
        XCTAssertTrue(숨김켬.contains(".gitignore"))
    }

    func test짝꿍노트숨김은그대로동작한다() throws {
        // 목록을 열어도 미디어의 짝꿍 노트는 계속 숨어야 한다(회귀 방지).
        try "소리".write(to: dir.appendingPathComponent("노래.mp3"), atomically: true, encoding: .utf8)
        try "메모".write(to: dir.appendingPathComponent("노래.mp3.md"), atomically: true, encoding: .utf8)

        let got = names(LibraryListing.entries(of: dir))
        XCTAssertTrue(got.contains("노래.mp3"))
        XCTAssertFalse(got.contains("노래.mp3.md"), "짝꿍 노트는 계속 숨어야 한다")
    }

    func test설정기본값은숨김끔이다() {
        XCTAssertFalse(AppSettings().showHiddenFiles)
    }

    func test옛설정파일에키가없어도끔으로읽는다() throws {
        let json = Data(#"{"theme":"system"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(decoded.showHiddenFiles)
    }
}
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `swift test --filter FileListingVisibilityTests`
Expected: 컴파일 실패 — `extra argument 'showHidden'`, `value of type 'AppSettings' has no member 'showHiddenFiles'`

- [ ] **Step 3: 목록 필터를 연다**

`Sources/App/AppState.swift` 의 `isListableInFileTree` 본문을 바꾼다. **함수는 지운다 하지 말고 남긴다** — 호출부가 여럿이고, 나중에 종류 숨기기를 붙일 자리다:

```swift
    /// 파일 트리·라이브러리에 나열할 파일인가.
    /// 파인더 대체(스펙 §3.5)로 **모든 파일**을 보여준다. 모르는 형식은
    /// DocumentKind가 .quickLook으로 갈라 애플 미리보기로 열리므로 눌러도 깨지지 않는다.
    /// (숨김 파일 제외는 열거 단계의 skipsHiddenFiles가 맡는다 — 여기 책임이 아니다.)
    static func isListableInFileTree(_ url: URL) -> Bool {
        true
    }
```

- [ ] **Step 4: 숨김 인자를 받는다**

`AppState.buildFileTree` 시그니처와 열거 옵션을 바꾼다:

```swift
    static func buildFileTree(at url: URL, expanded: Set<URL>,
                             showHidden: Bool = false, depth: Int = 0) -> [FileTreeItem] {
        guard depth < 10 else { return [] }

        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: options
        ) else { return [] }
```

같은 함수 안 재귀 호출에 `showHidden` 을 이어 넘긴다(빠뜨리면 펼친 하위 폴더만 숨김이 도로 켜진다):

```swift
                let children = isExpanded ? buildFileTree(at: itemURL, expanded: expanded,
                                                          showHidden: showHidden, depth: depth + 1) : []
```

`Sources/Services/LibraryListing.swift` 도 같은 모양으로:

```swift
    /// - `showHidden`이 false면 숨김 파일(.으로 시작)을 제외한다.
    static func entries(of folder: URL, showHidden: Bool = false) -> [FileTreeItem] {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden { options.insert(.skipsHiddenFiles) }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: options
        ) else { return [] }
```

`LibraryListing.swift` 머리 주석의 "숨김 파일(.으로 시작)은 제외한다" 줄도 `showHidden` 기준으로 고쳐 적는다.

- [ ] **Step 5: 설정 필드를 더한다**

`Sources/Models/Settings.swift` 에서 `showTabBar` 근처에 더한다:

```swift
    /// 숨김 파일(.으로 시작)을 트리·라이브러리에 표시할지. 보기 전용 — 검색 색인·볼트 작업은 영향 없다.
    var showHiddenFiles: Bool = false
```

`AppSettings` 에는 커스텀 디코더가 있다(`Settings.swift:142`). 거기 다른 `Bool` 설정과 **같은 모양**으로 한 줄 더한다(`d`는 그 함수가 이미 만들어 둔 기본값 인스턴스):

```swift
        showHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? d.showHiddenFiles
```

`CodingKeys`는 합성되므로 속성만 더하면 키가 따라온다.

- [ ] **Step 6: 호출부에 설정을 잇는다**

`AppState` 안에서 `buildFileTree`·`LibraryListing.entries` 를 부르는 곳에 `showHidden: settings.showHiddenFiles` 를 넘긴다. `loadFileTree`는 백그라운드 스캔 전에 메인에서 값을 스냅샷으로 캡처해 넘긴다(기존 `expandedFolders` 캡처와 같은 자리·같은 방식).

`Sources/Views/LibraryView.swift` 의 `LibraryListing.entries(of:)` 호출에도 `showHidden: appState.settings.showHiddenFiles` 를 넘기고, 폴더 갱신 트리거(`.task(id:)`)의 키에 이 값을 포함시켜 **설정을 바꾸면 즉시 다시 열거되게** 한다.

- [ ] **Step 7: 설정 화면에 스위치를 단다**

`Sources/Views/SettingsView.swift` 의 일반(General) 탭에서 `showTabBar`·`showStatusBar` 스위치 옆에 더한다:

```swift
                Toggle("숨김 파일 표시", isOn: $settings.showHiddenFiles)
                Text("점(.)으로 시작하는 파일과 폴더를 목록에 보여줍니다. 검색과 볼트 작업에는 영향이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

주변 스위치들이 쓰는 바인딩 방식(`@Bindable` 인지 `appState.settings` 직접인지)을 **그대로 따른다.**

- [ ] **Step 8: 테스트가 통과하는지 확인한다**

Run: `swift test --filter FileListingVisibilityTests`
Expected: PASS (7개)

- [ ] **Step 9: 전체 테스트로 회귀를 확인한다**

Run: `swift test 2>&1 | tail -20`
Expected: 실패 0.
`isListableInFileTree`가 항상 true가 되면서 **목록 개수를 단정하던 기존 테스트가 깨질 수 있다.** 깨지면 그 테스트가 옛 허용 목록 동작을 고정하던 것이므로, 새 동작에 맞게 기대값을 고친다(테스트를 지우지 말 것 — 짝꿍 노트 숨김 같은 다른 규칙까지 함께 검사하고 있을 수 있다).

- [ ] **Step 10: 커밋**

```bash
git add Sources/App/AppState.swift Sources/Services/LibraryListing.swift Sources/Models/Settings.swift Sources/Views/SettingsView.swift Sources/Views/LibraryView.swift Tests/CmdMDTests/FileListingVisibilityTests.swift
git commit -m "미리보기(2/7): 목록에 모든 파일 표시 + 숨김 파일 옵션(기본 끔)"
```

---

## Task 3: 미리보기 탭 화면

**Files:**
- Create: `Sources/Views/QuickLookReaderView.swift`
- Modify: `Sources/Views/MainEditorView.swift:25-46`

**Interfaces:**
- Consumes: Task 1의 `DocumentKind.quickLook`
- Produces:
  - `QuickLookReaderView(tabID: UUID, url: URL)` — 리더 화면
  - `DefaultAppInfo.openerName(for url: URL) -> String?`
  - Task 4가 채울 `appState.reopenAsText(tabID:)` 를 **호출한다**(이 태스크에서는 아직 없으므로 Step 3에서 임시 구현을 함께 넣는다)

- [ ] **Step 1: 미리보기 부품을 만든다**

`Sources/Views/QuickLookReaderView.swift`:

```swift
import SwiftUI
import Quartz
import AppKit

/// 애플 미리보기(QuickLook)를 담는 컨테이너.
/// QLPreviewView 생성이 실패할 수 있어(failable) 컨테이너가 감싸 안전하게 다룬다.
final class QuickLookContainerView: NSView {
    private var preview: QLPreviewView?
    /// 미리보기 부품을 못 만들었는가 — 화면이 백지로 남지 않게 안내를 띄운다(스펙 §4).
    private(set) var failed = false

    func show(_ url: URL) {
        if preview == nil && !failed {
            guard let view = QLPreviewView(frame: bounds, style: .normal) else {
                failed = true
                return
            }
            view.autostarts = true
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            preview = view
        }
        preview?.previewItem = url as NSURL
    }

    /// 뷰가 사라질 때 반드시 부른다 — QuickLook 자원을 놓아준다.
    func teardown() {
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
    }
}

/// SwiftUI에 얹는 껍데기.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QuickLookContainerView {
        let view = QuickLookContainerView()
        view.show(url)
        return view
    }

    func updateNSView(_ nsView: QuickLookContainerView, context: Context) {
        nsView.show(url)
    }

    static func dismantleNSView(_ nsView: QuickLookContainerView, coordinator: ()) {
        nsView.teardown()
    }
}

/// 이 파일을 여는 기본 앱 이름 — 버튼 문구용.
enum DefaultAppInfo {
    /// 기본 앱이 없거나 그게 우리 자신이면 nil(버튼을 숨긴다).
    static func openerName(for url: URL) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        if appURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return nil }
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.isEmpty ? nil : name
    }
}
```

- [ ] **Step 2: 탭 화면을 만든다**

같은 파일에 이어 쓴다:

```swift
/// 우리가 모르는 형식의 탭 화면 — 애플 미리보기 + 위쪽 버튼 줄(스펙 §4).
struct QuickLookReaderView: View {
    let tabID: UUID
    let url: URL
    @Environment(AppState.self) private var appState
    @State private var openerName: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let name = openerName {
                    Button("\(name)으로 열기") { NSWorkspace.shared.open(url) }
                }
                Button("글로 열기") {
                    Task { await appState.reopenAsText(tabID: tabID) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // 안내를 뒤에 깔고 미리보기를 위에 얹는다 — 미리보기를 못 만들면
            // 아무것도 덮이지 않아 안내가 그대로 보인다(백지 방지, 스펙 §4).
            ZStack {
                VStack(spacing: 6) {
                    Image(systemName: "doc.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("이 형식은 미리보기를 만들 수 없습니다.")
                        .foregroundStyle(.secondary)
                    Text("위의 버튼으로 다른 앱에서 열어 보세요.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                QuickLookPreview(url: url)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) {
            // NSWorkspace 조회는 디스크를 볼 수 있어 메인에서 붙들지 않는다.
            let name = await Task.detached { DefaultAppInfo.openerName(for: url) }.value
            openerName = name
        }
    }
}
```

- [ ] **Step 3: 리더에 갈래를 잇는다**

`Sources/Views/MainEditorView.swift` 의 `Group` 안, `media` 분기 **뒤** · `currentDocument` 분기 **앞**에 더한다:

```swift
            } else if appState.currentTabKind == .quickLook,
                      let url = appState.currentTabFileURL,
                      let tabID = appState.activeTabId {
                QuickLookReaderView(tabID: tabID, url: url)
                    // 파일이 바뀌면 미리보기를 새로 만든다.
                    .id(url)
```

- [ ] **Step 4: 임시 전환 함수를 넣는다**

Task 4가 제대로 구현하기 전까지 컴파일이 되도록, `Sources/App/AppState.swift` 에 자리만 만든다:

```swift
    /// 미리보기 탭을 편집기로 바꾼다(스펙 §4). Task 4에서 본 구현.
    @MainActor
    func reopenAsText(tabID: UUID) async {
        // Task 4에서 채운다.
    }
```

- [ ] **Step 5: 빌드와 전체 테스트를 확인한다**

Run: `swift build 2>&1 | tail -20`
Expected: 경고 0, 오류 0

Run: `swift test 2>&1 | tail -20`
Expected: 실패 0

- [ ] **Step 6: 커밋**

```bash
git add Sources/Views/QuickLookReaderView.swift Sources/Views/MainEditorView.swift Sources/App/AppState.swift
git commit -m "미리보기(3/7): 애플 미리보기 탭 화면 + 기본 앱 열기 버튼"
```

---

## Task 4: "글로 열기" 전환

**Files:**
- Modify: `Sources/App/AppState.swift` (Task 3에서 만든 빈 `reopenAsText`)
- Test: `Tests/CmdMDTests/AppQuickLookTests.swift`

**Interfaces:**
- Consumes: Task 3의 빈 `AppState.reopenAsText(tabID:) async`
- Produces: 같은 함수의 본 구현 — 탭의 `kind`를 `.markdown`으로 바꾸고 `documents`·`originalContents`를 채운다

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/CmdMDTests/AppQuickLookTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// "글로 열기" 전환(스펙 §4) — 미리보기 탭을 편집기로.
@MainActor
final class AppQuickLookTests: XCTestCase {

    private var tempDir: URL!
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = TempDataDirectory.make()
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("글로열기-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TempDataDirectory.cleanup(tempDir)
        try? FileManager.default.removeItem(at: workDir)
        tempDir = nil
        workDir = nil
        try super.tearDownWithError()
    }

    func test글로열기가탭을편집기로바꾼다() async throws {
        let file = workDir.appendingPathComponent("설정.mdx")
        try "# 제목\n본문입니다".write(to: file, atomically: true, encoding: .utf8)

        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: file, title: "설정", kind: .quickLook)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        await appState.reopenAsText(tabID: tab.id)

        XCTAssertEqual(appState.tabs.first?.kind, .markdown)
        let docID = try XCTUnwrap(appState.tabs.first?.documentId)
        XCTAssertNotNil(appState.documents[docID], "문서가 실려야 한다")
        XCTAssertEqual(appState.documents[docID]?.fullText, "# 제목\n본문입니다")
        XCTAssertNotNil(appState.originalContents[docID], "저장 기준선이 잡혀야 한다")
    }

    func test미리보기탭이아니면아무일도하지않는다() async throws {
        let file = workDir.appendingPathComponent("사진.png")
        try "가짜".write(to: file, atomically: true, encoding: .utf8)

        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: file, title: "사진", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        await appState.reopenAsText(tabID: tab.id)

        XCTAssertEqual(appState.tabs.first?.kind, .image, "이미지 탭은 그대로여야 한다")
    }

    func test없는탭이면조용히넘어간다() async {
        let appState = AppState(dataDirectory: tempDir)
        await appState.reopenAsText(tabID: UUID())
        XCTAssertTrue(appState.tabs.isEmpty)
    }
}
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `swift test --filter AppQuickLookTests`
Expected: FAIL — `XCTAssertEqual failed: (quickLook) is not equal to (markdown)` (빈 구현이라 아무 일도 안 일어난다)

- [ ] **Step 3: 본 구현을 쓴다**

`Sources/App/AppState.swift` 의 빈 `reopenAsText` 를 채운다:

```swift
    /// 미리보기 탭을 편집기로 바꾼다(스펙 §4 탈출구).
    /// 맥이 "글자 아님"이라 답했지만 실제로는 글자인 파일(.mdx 등)을 구제한다.
    /// 그 탭이 살아 있는 동안만 유지된다 — 닫았다 열면 다시 미리보기다.
    @MainActor
    func reopenAsText(tabID: UUID) async {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].kind == .quickLook,
              let url = tabs[index].fileURL else { return }
        do {
            let document = try await fileService.loadDocument(from: url)
            // await 뒤에는 탭 배열이 바뀌었을 수 있다 — 인덱스를 다시 찾는다.
            guard let current = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            documents[document.id] = document
            originalContents[document.id] = document.fullText
            tabs[current].documentId = document.id
            tabs[current].kind = .markdown
            tabs[current].title = document.displayTitle
            startWatchingFile(at: url, for: tabID)
            harvestTags(from: document)
        } catch {
            errorMessage = "글로 열지 못했습니다: \(error.localizedDescription)"
        }
    }
```

`startWatchingFile` 이 `private` 이면 같은 타입 안에서 부르므로 그대로 된다. 컴파일 오류가 나면 접근 수준을 `private` → 기본(internal)으로 낮춘다.

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `swift test --filter AppQuickLookTests`
Expected: PASS (3개)

- [ ] **Step 5: 전체 테스트**

Run: `swift test 2>&1 | tail -20`
Expected: 실패 0

- [ ] **Step 6: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppQuickLookTests.swift
git commit -m "미리보기(4/7): '글로 열기' — 미리보기 탭을 편집기로 전환"
```

---

## Task 5: 스페이스바 키 라우팅

**Files:**
- Modify: `Sources/App/AppState.swift` (상태 + `handleQuickLookKeyEvent`)
- Modify: `Sources/App/CmdMDApp.swift:418-421`
- Test: `Tests/CmdMDTests/AppQuickLookTests.swift` (같은 파일에 이어 쓴다)

**Interfaces:**
- Consumes: 기존 `AppState.responderYieldsFileKeys(_:)`, `AppState.fileSelection`, `AppState.libraryOrderedURLs`
- Produces:
  - `AppState.quickLookURLs: [URL]`, `AppState.quickLookIndex: Int`, `AppState.isQuickLookPresented: Bool`
  - `AppState.quickLookCandidates() -> [URL]`
  - `AppState.openQuickLook(urls: [URL])`, `AppState.closeQuickLook()`
  - `AppState.stepQuickLook(by delta: Int)`
  - `AppState.handleQuickLookKeyEvent(_ event: NSEvent) -> Bool`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/CmdMDTests/AppQuickLookTests.swift` 클래스 안에 이어 쓴다:

```swift
    // MARK: - 스페이스바 빠른 보기(스펙 §5)

    func test선택한파일들이화면순서대로후보가된다() {
        let appState = AppState(dataDirectory: tempDir)
        let a = URL(fileURLWithPath: "/tmp/가.png")
        let b = URL(fileURLWithPath: "/tmp/나.pdf")
        let c = URL(fileURLWithPath: "/tmp/다.zip")
        appState.libraryOrderedURLs = [a, b, c]
        appState.fileSelection = [c, a]

        XCTAssertEqual(appState.quickLookCandidates(), [a, c],
                       "화면에 보이는 순서를 따라야 한다")
    }

    func test선택이없으면후보가없다() {
        let appState = AppState(dataDirectory: tempDir)
        appState.libraryOrderedURLs = [URL(fileURLWithPath: "/tmp/가.png")]
        appState.fileSelection = []

        XCTAssertTrue(appState.quickLookCandidates().isEmpty)
    }

    func test열고닫기가상태를바꾼다() {
        let appState = AppState(dataDirectory: tempDir)
        let urls = [URL(fileURLWithPath: "/tmp/가.png"), URL(fileURLWithPath: "/tmp/나.zip")]

        appState.openQuickLook(urls: urls)
        XCTAssertTrue(appState.isQuickLookPresented)
        XCTAssertEqual(appState.quickLookURLs, urls)
        XCTAssertEqual(appState.quickLookIndex, 0)

        appState.closeQuickLook()
        XCTAssertFalse(appState.isQuickLookPresented)
        XCTAssertTrue(appState.quickLookURLs.isEmpty)
    }

    func test좌우이동은양끝에서멈춘다() {
        let appState = AppState(dataDirectory: tempDir)
        appState.openQuickLook(urls: [URL(fileURLWithPath: "/tmp/가.png"),
                                      URL(fileURLWithPath: "/tmp/나.zip")])

        appState.stepQuickLook(by: -1)
        XCTAssertEqual(appState.quickLookIndex, 0, "첫 항목에서 왼쪽은 제자리")

        appState.stepQuickLook(by: 1)
        XCTAssertEqual(appState.quickLookIndex, 1)

        appState.stepQuickLook(by: 1)
        XCTAssertEqual(appState.quickLookIndex, 1, "마지막에서 오른쪽은 제자리")
    }

    func test글자입력중이면스페이스를가로채지않는다() {
        // 이 저장소에서 세 번 반복된 키 강탈 결함 방지(스펙 §5).
        let field = NSTextField(string: "검색어")
        XCTAssertTrue(AppState.responderYieldsFileKeys(field.currentEditor() ?? field),
                      "글자 입력칸은 파일 키를 양보받아야 한다")
    }

    func test빈선택에서는빠른보기가열리지않는다() {
        let appState = AppState(dataDirectory: tempDir)
        appState.fileSelection = []
        appState.openQuickLook(urls: appState.quickLookCandidates())
        XCTAssertFalse(appState.isQuickLookPresented, "후보가 없으면 열리지 않는다")
    }
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `swift test --filter AppQuickLookTests`
Expected: 컴파일 실패 — `value of type 'AppState' has no member 'quickLookCandidates'`

- [ ] **Step 3: 상태와 동작을 더한다**

`Sources/App/AppState.swift` 의 `fileSelection`·`libraryOrderedURLs` 선언 근처에 상태를 더한다:

```swift
    // MARK: - 스페이스바 빠른 보기(스펙 §5)

    /// 빠른 보기로 넘겨볼 파일들(화면 표시 순서).
    var quickLookURLs: [URL] = []
    /// 지금 보고 있는 항목 위치.
    var quickLookIndex: Int = 0
    /// 빠른 보기 오버레이가 떠 있는가.
    var isQuickLookPresented: Bool = false
```

동작을 더한다(`handleFileOpsKeyEvent` 근처가 자연스럽다):

```swift
    /// 빠른 보기 후보 — 선택한 파일을 화면 표시 순서대로.
    /// 표시 목록(libraryOrderedURLs)을 진실원으로 삼는다(F1b ⌘A 관례 — 화면에
    /// 없는 파일이 선택에 새어 들어오는 것을 막는다).
    func quickLookCandidates() -> [URL] {
        guard !fileSelection.isEmpty else { return [] }
        let ordered = libraryOrderedURLs.filter { fileSelection.contains($0) }
        if !ordered.isEmpty { return ordered }
        // 트리 ⌘클릭처럼 표시 목록 밖에서 고른 경우 — 경로순으로 안정 정렬.
        return fileSelection.sorted { $0.path < $1.path }
    }

    func openQuickLook(urls: [URL]) {
        guard !urls.isEmpty else { return }
        quickLookURLs = urls
        quickLookIndex = 0
        isQuickLookPresented = true
    }

    func closeQuickLook() {
        isQuickLookPresented = false
        quickLookURLs = []
        quickLookIndex = 0
    }

    /// 좌우 이동 — 양끝에서 멈춘다(감싸지 않는다).
    func stepQuickLook(by delta: Int) {
        guard !quickLookURLs.isEmpty else { return }
        quickLookIndex = min(max(quickLookIndex + delta, 0), quickLookURLs.count - 1)
    }

    /// 빠른 보기 키 라우팅 — 로컬 NSEvent 모니터에서 **파일 키보다 먼저** 호출한다.
    /// true = 소비. 전역 .keyboardShortcut은 쓰지 않는다(F1b에서 확립된 규칙).
    func handleQuickLookKeyEvent(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.canBecomeMain else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags.isEmpty else { return false }

        // 떠 있을 때의 키는 먼저 처리한다 — 미리보기 부품이 먼저 먹지 않도록.
        if isQuickLookPresented {
            switch event.keyCode {
            case 49, 53:            // 스페이스 · ⎋
                closeQuickLook()
                return true
            case 123:               // ←
                stepQuickLook(by: -1)
                return true
            case 124:               // →
                stepQuickLook(by: 1)
                return true
            default:
                return false
            }
        }

        guard event.keyCode == 49 else { return false }   // 스페이스
        // 글자 입력칸·미리보기(WKWebView)·PDF가 활성이면 양보한다.
        // 스페이스는 띄어쓰기·스크롤에 쓰이므로 가로채면 즉시 치명적이다.
        if Self.responderYieldsFileKeys(window.firstResponder) { return false }

        let candidates = quickLookCandidates()
        guard !candidates.isEmpty else { return false }
        openQuickLook(urls: candidates)
        return true
    }
```

- [ ] **Step 4: 키 모니터에 잇는다**

`Sources/App/CmdMDApp.swift:418` 의 모니터를 바꾼다. **빠른 보기를 먼저** 태워야 ⎋가 선택 해제로 새지 않는다:

```swift
        fileOpsMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 빠른 보기가 먼저 — 떠 있을 때의 ⎋가 선택 해제로 새지 않게.
            if AppState.shared?.handleQuickLookKeyEvent(event) == true { return nil }
            if AppState.shared?.handleFileOpsKeyEvent(event) == true { return nil }
            return event
        }
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `swift test --filter AppQuickLookTests`
Expected: PASS (9개 — Task 4의 3개 + 이번 6개)

- [ ] **Step 6: 전체 테스트**

Run: `swift test 2>&1 | tail -20`
Expected: 실패 0

- [ ] **Step 7: 커밋**

```bash
git add Sources/App/AppState.swift Sources/App/CmdMDApp.swift Tests/CmdMDTests/AppQuickLookTests.swift
git commit -m "미리보기(5/7): 스페이스바 빠른 보기 키 라우팅 — 입력 중엔 양보"
```

---

## Task 6: 스페이스바 빠른 보기 화면

**Files:**
- Create: `Sources/Views/QuickLookQuickPanel.swift`
- Modify: `Sources/Views/ContentView.swift`
- Modify: `Sources/App/AppState.swift` (`relaunchForUpdate` 한 줄)

**Interfaces:**
- Consumes: Task 5의 `quickLookURLs`·`quickLookIndex`·`isQuickLookPresented`·`closeQuickLook()`·`stepQuickLook(by:)`, Task 3의 `QuickLookPreview`
- Produces: `QuickLookQuickPanel()` — ContentView 위에 얹는 오버레이

- [ ] **Step 1: 오버레이 화면을 만든다**

`Sources/Views/QuickLookQuickPanel.swift`:

```swift
import SwiftUI
import AppKit

/// 스페이스바 빠른 보기(스펙 §5) — 탭을 만들지 않고 크게 훑어본다.
///
/// **시트가 아니라 오버레이인 이유**: 떠 있는 시트는 `NSApp.terminate`를 막는다
/// (자동 업데이트 '지금 다시 시작' 사고에서 실측·변이 시험으로 확정). 빠른 보기를
/// 열어 둔 채 업데이트 재시작을 누르면 같은 증상이 재현되므로 오버레이로 둔다.
struct QuickLookQuickPanel: View {
    @Environment(AppState.self) private var appState

    private var currentURL: URL? {
        guard appState.quickLookURLs.indices.contains(appState.quickLookIndex) else { return nil }
        return appState.quickLookURLs[appState.quickLookIndex]
    }

    var body: some View {
        if appState.isQuickLookPresented, let url = currentURL {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { appState.closeQuickLook() }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if appState.quickLookURLs.count > 1 {
                            Text("\(appState.quickLookIndex + 1) / \(appState.quickLookURLs.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.closeQuickLook()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("닫기 (스페이스 또는 esc)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    QuickLookPreview(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: 900, maxHeight: 700)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 12))
                .shadow(radius: 24)
                .padding(40)
            }
            .transition(.opacity)
        }
    }
}
```

- [ ] **Step 2: ContentView에 얹는다**

`Sources/Views/ContentView.swift` 의 최상위 `HStack` 에 오버레이를 단다. `.inspector`·Claude 패널보다 **위**에 오도록 바깥쪽 수식자로 붙인다:

```swift
        .overlay {
            QuickLookQuickPanel()
        }
```

붙이는 자리는 `HStack { … }` 전체가 끝난 뒤, 기존 `.sheet(...)` 수식자들과 같은 층이다.

- [ ] **Step 3: 업데이트 재시작과의 충돌을 막는다**

`Sources/App/AppState.swift` 의 `relaunchForUpdate` 에서 About 시트를 닫는 줄 바로 옆에 더한다:

```swift
        showAbout = false
        // 빠른 보기가 떠 있어도 종료를 막지 않도록 함께 닫는다(오버레이라 종료는
        // 막지 않지만, 새 앱이 뜬 뒤 유령 화면이 남지 않게).
        closeQuickLook()
```

- [ ] **Step 4: 빌드와 전체 테스트**

Run: `swift build 2>&1 | tail -20`
Expected: 경고 0, 오류 0

Run: `swift test 2>&1 | tail -20`
Expected: 실패 0

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/QuickLookQuickPanel.swift Sources/Views/ContentView.swift Sources/App/AppState.swift
git commit -m "미리보기(6/7): 스페이스바 빠른 보기 화면 — 시트 아닌 오버레이"
```

---

## Task 7: 글자 파일 색인 확장

**Files:**
- Modify: `Sources/Services/ContentExtractor.swift`
- Modify: `Sources/Services/SearchIndex.swift`
- Modify: `Sources/App/AppState.swift` (다시 훑기 트리거)
- Test: `Tests/CmdMDTests/ContentExtractorTextTests.swift`

**Interfaces:**
- Consumes: Task 1의 `QuickLookRouting.opensAsText(_:)`
- Produces:
  - `ContentExtractor.maxTextBytes: Int` (5 MB)
  - `ContentExtractor.localBody(for:)` 동작 확장
  - `SearchIndex.extractorVersion` 저장·조회, `SearchIndex.currentExtractorVersion`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/CmdMDTests/ContentExtractorTextTests.swift`:

```swift
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
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `swift test --filter ContentExtractorTextTests`
Expected: 컴파일 실패 — `type 'ContentExtractor' has no member 'maxTextBytes'`

- [ ] **Step 3: 추출기를 넓힌다**

`Sources/Services/ContentExtractor.swift` 를 바꾼다:

```swift
import Foundation
import PDFKit

/// 파일 URL → 인덱싱 본문. 없으면 nil(파일명만 인덱싱).
/// office는 kordoc(Process) 비동기 추출, 그 외(글자/pdf)는 동기 로컬 추출.
enum ContentExtractor {

    /// 본문으로 읽을 최대 크기. 큰 기록 파일이 통째로 메모리·색인에 들어가는 것을 막는다.
    /// 넘으면 nil → 파일 이름만 색인(스펙 §3.6).
    static let maxTextBytes = 5 * 1024 * 1024

    /// kordoc 없이 즉시 추출 가능한 종류(글자/pdf)만. 미지원·없는 파일은 nil.
    static func localBody(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()

        if DocumentKind.pdfExtensions.contains(ext) {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var parts: [String] = []
            for i in 0..<pdf.pageCount {
                if let s = pdf.page(at: i)?.string { parts.append(s) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }

        // 글자 파일 판정은 QuickLookRouting 하나만 쓴다 — 여는 규칙과 색인 규칙이
        // 어긋나지 않게(스펙 §3.6).
        guard QuickLookRouting.opensAsText(extension: ext) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxTextBytes else { return nil }

        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 종류별 본문. office면 kordoc 분기, 그 외는 localBody.
    static func body(for url: URL, kordoc: KordocService) async -> String? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.officeExtensions.contains(ext) {
            return try? await kordoc.markdown(for: url)
        }
        return localBody(for: url)
    }
}
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `swift test --filter ContentExtractorTextTests`
Expected: PASS (5개)

Run: `swift test --filter ContentExtractorTests`
Expected: PASS — 기존 추출기 테스트가 깨지면 옛 목록(`md`·`markdown`·`txt`) 동작을 고정하던 것이므로 새 규칙에 맞게 기대값을 고친다.

- [ ] **Step 5: 규칙 판 번호로 한 번 다시 훑는다**

`Sources/Services/SearchIndex.swift` 의 `deinit`(62줄) 아래, `exec` 근처에 더한다. 별도 표를 만들지 않고 SQLite가 파일마다 갖고 있는 정수 칸(`PRAGMA user_version`)을 쓴다 — 새 표·새 마이그레이션이 필요 없다:

```swift
    /// 추출 규칙 판 번호. 올리면 등록 폴더를 한 번 다시 훑는다.
    /// 0(또는 1) → 2: 글자 파일(json·swift·csv 등)을 본문 색인에 포함(스펙 §3.6).
    static let currentExtractorVersion = 2

    /// 이 색인 파일에 적힌 판 번호. 새 DB·옛 DB는 0.
    var storedExtractorVersion: Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// 판 번호를 적는다(다시 훑기를 건 뒤 호출).
    /// PRAGMA는 바인딩을 받지 않아 문자열로 넣는다 — 값이 우리 상수(Int)라 안전하다.
    func setExtractorVersion(_ version: Int) {
        exec("PRAGMA user_version = \(version);")
    }
```

`Sources/App/AppState.swift:1601-1608` 의 `reindexAfterSchemaMigration` 을 바꾼다:

```swift
    /// 인덱스 DB가 스키마 변경으로 재구성됐거나 추출 규칙이 바뀌었으면 등록된 모든 폴더를 재인덱싱한다.
    @MainActor
    private func reindexAfterSchemaMigration() async {
        let schemaChanged = await searchIndex.didResetForSchemaChange
        // 추출 규칙이 넓어져도 파일 수정 시각은 그대로라 needsIndex만으로는 갱신되지
        // 않는다 → 판 번호로 한 번 다시 훑는다(스펙 §3.6).
        let extractorChanged = await searchIndex.storedExtractorVersion < SearchIndex.currentExtractorVersion
        guard schemaChanged || extractorChanged else { return }
        for folder in settings.indexedFolders {
            reindexFolder(folder)
        }
        await searchIndex.setExtractorVersion(SearchIndex.currentExtractorVersion)
    }
```

새로 설치한 경우 판 번호가 0이라 이 분기를 타지만, 등록 폴더가 비어 있어 아무 일도 일어나지 않고 번호만 적힌다.

- [ ] **Step 6: 전체 테스트**

Run: `swift test 2>&1 | tail -20`
Expected: 실패 0

- [ ] **Step 7: 커밋**

```bash
git add Sources/Services/ContentExtractor.swift Sources/Services/SearchIndex.swift Sources/App/AppState.swift Tests/CmdMDTests/ContentExtractorTextTests.swift
git commit -m "미리보기(7/7): 글자 파일 색인 확장 — 여는 규칙을 색인이 재사용"
```

---

## 마무리 — 실기 확인 (자동 테스트로는 원리상 불가)

이 저장소에서 결함은 늘 여기서 나왔다(AVKit 링크 누락·배타적 접근 위반·드래그 파스테보드·한글 입력기). **재패키징·설치 후** 실제로 눌러 확인한다.

```bash
./scripts/package_app.sh
```

- [ ] `.pptx` 열어 슬라이드 넘김 / `.key` `.zip` `.psd` 열어봄
- [ ] "○○으로 열기" 버튼이 실제 그 앱을 띄움
- [ ] `.mdx` 열어 "글로 열기"로 편집기 전환
- [ ] 라이브러리에서 스페이스 → 열림, 다시 스페이스·`esc` → 닫힘
- [ ] 여러 개 골라 `←` `→`로 넘김
- [ ] **검색창에 글자 치는 중 스페이스 → 띄어쓰기가 되고 미리보기가 안 뜸**(키 강탈 회귀)
- [ ] 미리보기 화면 안에서 스페이스가 닫기로 듣는지(스펙 §5의 〔실기 확인 필요〕)
- [ ] 기존 여섯 종류가 그대로 열림
- [ ] 다운로드 폴더에 `.pptx`·`.zip`이 목록에 보임
- [ ] 설정에서 숨김 파일 켜기 → `.gitignore` 나타남, 끄면 사라짐
- [ ] 등록 폴더 다시 훑은 뒤 `json` 파일 **내용**으로 검색해 잡힘
