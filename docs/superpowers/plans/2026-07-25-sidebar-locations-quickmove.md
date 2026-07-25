# D+B. 기본 위치 + 빠른 이동 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사이드바에 홈·데스크탑·다운로드·문서를 파인더처럼 항상 보이게 하고(D), 사용자가 직접 등록한 "빠른 이동 목록"에서 클릭 한 번으로 파일을 옮길 수 있게 한다(B). 이동 실행 자체는 F1a/F1b가 이미 만든 `performBatchMove`를 그대로 재사용 — 새 이동 로직은 만들지 않는다.

**Architecture:** D는 표시만 하는 정적 목록(저장 없음). B는 새 모델 `QuickMoveFolder` + `AppState.quickMoveFolders`(사용자가 우클릭으로 등록/해제, `favorites` 저장 관례 재사용) + 새 화면 `QuickMoveSheet`(목적지 클릭 → 기존 `performBatchMove` 호출). 신규 코드는 전부 새 파일로 두고 기존 파일은 최소한만 손댄다.

**Tech Stack:** Swift 5.9+ / SwiftUI, XCTest. 새 패키지 의존성 없음.

## Global Constraints

- 새 패키지 의존성 0.
- macOS 14+ / Swift 5.9+.
- 코드 주석·커밋 메시지·UI 문구는 **한국어**.
- 글에서 '박다/박는다/박았다' 표현은 쓰지 않는다.
- **원본 파일 불변.** 이 작업의 어떤 경로도 사용자 파일을 쓰거나 지우지 않는다 — 이동은 기존 `FileOperations.move`(휴지통 이동만, 되돌리기 가능)를 그대로 통과시킨다.
- 신규 기능은 **별도 파일**로 분리한다.
- 각 태스크는 `swift test` 전체 통과로 끝난다. **현재 기준선 872개**(XCTest 854 + Swift Testing 18, 2026-07-25 재확인). 기존 테스트를 깨뜨리지 않는다.
- 테스트는 XCTest, `@testable import CmdMD`. `AppState`를 쓰는 테스트는 반드시 `AppState(dataDirectory: TempDataDirectory.make())`로 격리한다.
- 이동은 기존 "폴더로 이동…"(NSOpenPanel)을 대체하지 않는다 — 그대로 둔 채 옆에 빠른 경로만 추가한다.

---

## 파일 구조

**새로 만드는 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Models/QuickMoveFolder.swift` | `Identifiable·Equatable·Codable` 모델(id·url·addedAt) |
| `Sources/Views/QuickMoveSheet.swift` | 빠른 이동 목적지 시트 — 등록된 폴더 클릭 시 이동, 빈 상태 안내, "다른 폴더로 이동…" 버튼 |
| `Tests/CmdMDTests/AppQuickMoveTests.swift` | 등록·해제·중복 방지·로드 시 존재하지 않는 경로 필터링·이동 트리거 |

**손대는 기존 파일** (전부 최소 변경)

| 파일 | 변경 |
|---|---|
| `Sources/Models/Shortcuts.swift` | `.quickMove` 케이스 + 기본 단축키 `⌥⌘M` |
| `Sources/App/AppState.swift` | `quickMoveFolders` 상태(로드·저장) · `addToQuickMoveFolders`/`removeFromQuickMoveFolders` · `showQuickMove`/`quickMoveTargets` · `promptQuickMove(urls:)` |
| `Sources/Views/SidebarView.swift` | `FavoritesListView`에 "기본 위치" 섹션 신설 · `FileTreeContextMenu`·`FavoriteRow` 컨텍스트 메뉴에 "빠른 이동 목록에 추가/제거" + "빠른 이동…" 버튼 |
| `Sources/Views/LibraryView.swift`(`LibraryCellContextMenu`) | 폴더 셀에 동일 항목 추가 |
| `Sources/Views/BatchSelectionMenu.swift` | "빠른 이동…" 버튼 추가(기존 "폴더로 이동…" 유지) |
| `Sources/Views/ContentView.swift` | `.sheet(isPresented: $state.showQuickMove)` 배선 |
| `Sources/App/CmdMDApp.swift` | File 메뉴에 "빠른 이동…" 버튼 + `.appShortcut(.quickMove)` |

---

## Task 1: `QuickMoveFolder` 모델 + `AppState` 저장소

**Files:**
- Create: `Sources/Models/QuickMoveFolder.swift`
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/CmdMDTests/AppQuickMoveTests.swift`

**Interfaces:**
- Consumes: (없음 — 첫 태스크)
- Produces:
  - `QuickMoveFolder` (struct: `id: UUID`, `url: URL`, `addedAt: Date`)
  - `AppState.quickMoveFolders: [QuickMoveFolder]`
  - `AppState.addToQuickMoveFolders(_ url: URL)`
  - `AppState.removeFromQuickMoveFolders(_ folder: QuickMoveFolder)`
  - `AppState.isQuickMoveFolder(_ url: URL) -> Bool`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`Tests/CmdMDTests/AppQuickMoveTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 빠른 이동 목록 등록·해제(스펙 §4.1 — 즐겨찾기와 별개, 사용자가 직접 등록).
final class AppQuickMoveTests: XCTestCase {
    var appState: AppState!
    var tempData: URL!
    var folder: URL!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        appState = AppState(dataDirectory: tempData)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickmove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func test등록하면목록에추가된다() {
        appState.addToQuickMoveFolders(folder)
        XCTAssertEqual(appState.quickMoveFolders.map(\.url), [folder])
        XCTAssertTrue(appState.isQuickMoveFolder(folder))
    }

    func test같은폴더재등록은무시된다() {
        appState.addToQuickMoveFolders(folder)
        appState.addToQuickMoveFolders(folder)
        XCTAssertEqual(appState.quickMoveFolders.count, 1)
    }

    func test해제하면목록에서빠진다() {
        appState.addToQuickMoveFolders(folder)
        let entry = appState.quickMoveFolders[0]
        appState.removeFromQuickMoveFolders(entry)
        XCTAssertTrue(appState.quickMoveFolders.isEmpty)
        XCTAssertFalse(appState.isQuickMoveFolder(folder))
    }

    func test저장후다시읽으면유지된다() {
        appState.addToQuickMoveFolders(folder)
        appState.saveUserData()

        let reloaded = AppState(dataDirectory: tempData)
        XCTAssertEqual(reloaded.quickMoveFolders.map(\.url), [folder])
    }

    func test존재하지않는경로는로드시걸러진다() {
        appState.addToQuickMoveFolders(folder)
        appState.saveUserData()
        try? FileManager.default.removeItem(at: folder)

        let reloaded = AppState(dataDirectory: tempData)
        XCTAssertTrue(reloaded.quickMoveFolders.isEmpty)
    }
}
```

- [ ] **Step 2: 실패하는지 확인한다**

Run: `swift test --filter AppQuickMoveTests`
Expected: 컴파일 실패 — `type 'AppState' has no member 'quickMoveFolders'` 등.

- [ ] **Step 3: 모델을 만든다**

`Sources/Models/QuickMoveFolder.swift`:

```swift
import Foundation

/// 사용자가 직접 등록한 "빠른 이동" 목적지 폴더 (스펙 §4.1).
/// 즐겨찾기(`FavoriteItem`, "열어볼 곳")와 성격이 달라 별도 타입·별도 저장소로 둔다.
struct QuickMoveFolder: Identifiable, Equatable, Codable {
    let id: UUID
    var url: URL
    var addedAt: Date

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
    }
}
```

- [ ] **Step 4: `AppState`에 배선한다**

`favorites` 선언 바로 다음에 추가(`AppState.swift`, 대략 103번째 줄):

```swift
    var quickMoveFolders: [QuickMoveFolder] = []
```

`loadUserData()`의 favorites 로드 블록 다음에 추가:

```swift
        if let loaded = load([QuickMoveFolder].self, from: "quickmove-folders.json") {
            quickMoveFolders = loaded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
```

`saveUserData()`의 `save(favorites, to: "favorites.json")` 다음에 추가:

```swift
        save(quickMoveFolders, to: "quickmove-folders.json")
```

`// MARK: - Recents & Favorites` 블록의 `removeFromFavorites` 다음에 새 섹션 추가:

```swift
    // MARK: - Quick Move

    func addToQuickMoveFolders(_ url: URL) {
        guard !quickMoveFolders.contains(where: { $0.url == url }) else { return }
        quickMoveFolders.append(QuickMoveFolder(url: url))
        saveUserData()
        showToast("빠른 이동 목록에 추가했습니다")
    }

    func removeFromQuickMoveFolders(_ folder: QuickMoveFolder) {
        quickMoveFolders.removeAll { $0.id == folder.id }
        saveUserData()
    }

    func isQuickMoveFolder(_ url: URL) -> Bool {
        quickMoveFolders.contains(where: { $0.url == url })
    }
```

- [ ] **Step 5: 통과 확인 + 전체 회귀**

Run: `swift test --filter AppQuickMoveTests` → 5개 통과
Run: `swift test` → 기존 872개 + 신규 5개, 실패 0.

- [ ] **Step 6: 커밋**

`git commit -m "빠른 이동(1/4): QuickMoveFolder 모델 + AppState 등록·해제·저장"`

---

## Task 2: 단축키 `.quickMove`

**Files:**
- Modify: `Sources/Models/Shortcuts.swift`
- Test: 기존 `Tests/CmdMDTests/AppQuickMoveTests.swift`에 추가

**Interfaces:**
- Consumes: Task 1 없음(독립)
- Produces: `AppShortcut.quickMove`, `.title`, `.defaultBinding == ⌥⌘M`

- [ ] **Step 1: 실패하는 테스트를 추가한다**

`AppQuickMoveTests.swift`에 추가:

```swift
    func test빠른이동단축키는옵션커맨드M이다() {
        let binding = AppShortcut.quickMove.defaultBinding
        XCTAssertEqual(binding.key, "m")
        XCTAssertTrue(binding.command)
        XCTAssertTrue(binding.option)
        XCTAssertFalse(binding.shift)
    }

    func test빠른이동단축키는다른커맨드와겹치지않는다() {
        let quickMove = AppShortcut.quickMove.defaultBinding
        for shortcut in AppShortcut.allCases where shortcut != .quickMove {
            let other = shortcut.defaultBinding
            let same = other.key == quickMove.key && other.command == quickMove.command
                && other.shift == quickMove.shift && other.option == quickMove.option
                && other.control == quickMove.control
            XCTAssertFalse(same, "\(shortcut)와 단축키가 겹친다")
        }
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppQuickMoveTests`
Expected: `type 'AppShortcut' has no member 'quickMove'`

- [ ] **Step 3: 케이스를 추가한다**

`Sources/Models/Shortcuts.swift`, `enum AppShortcut`의 `case navigateUp` 다음:

```swift
    case quickMove
```

`title`의 `case .navigateUp: ...` 다음:

```swift
        case .quickMove: return "Quick Move… (빠른 이동)"
```

`defaultBinding`의 `case .navigateUp: ...` 다음:

```swift
        case .quickMove: return KeyBinding(key: "m", command: true, option: true)  // ⌥⌘M
```

- [ ] **Step 4: 통과 확인 + 전체 회귀**

Run: `swift test --filter AppQuickMoveTests` → 7개 통과
Run: `swift test` → 실패 0.

- [ ] **Step 5: 커밋**

`git commit -m "빠른 이동(2/4): 단축키 ⌥⌘M 등록"`

---

## Task 3: D. 사이드바 "기본 위치" 섹션

**Files:**
- Modify: `Sources/Views/SidebarView.swift`

**Interfaces:**
- Consumes: (없음 — 순수 표시, 새 상태 없음)
- Produces: `FavoritesListView` 상단에 고정 "기본 위치" 4행

이 태스크는 뷰 전용이라 XCTest로 검증할 로직이 없다(SwiftUI 렌더는 스냅샷 인프라 부재 — 기존 프로젝트 관례와 동일하게 수동 스모크로 확인, Task 6에서 함께 확인).

- [ ] **Step 1: 기본 위치 목록 헬퍼를 추가한다**

`SidebarView.swift`의 `FavoritesListView` 앞에 추가:

```swift
/// 파인더처럼 항상 보이는 고정 위치 4개(스펙 §3). 저장하지 않고 매번 계산.
private struct DefaultLocation: Identifiable {
    let id: String
    let name: String
    let icon: String
    let url: URL
}

private func defaultLocations() -> [DefaultLocation] {
    let fm = FileManager.default
    let candidates: [(String, String, URL)] = [
        ("Home", "house", fm.homeDirectoryForCurrentUser),
        ("Desktop", "menubar.dock.rectangle", fm.urls(for: .desktopDirectory, in: .userDomainMask).first),
        ("Downloads", "arrow.down.circle", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first),
        ("Documents", "doc.on.doc", fm.urls(for: .documentDirectory, in: .userDomainMask).first)
    ].compactMap { name, icon, url in url.map { (name, icon, $0) } }

    return candidates
        .filter { fm.fileExists(atPath: $0.2.path) }
        .map { DefaultLocation(id: $0.0, name: $0.0, icon: $0.1, url: $0.2) }
}
```

(위 튜플 배열의 세 번째 원소가 `URL?`이라 `compactMap`으로 nil을 거른다 — `desktopDirectory` 등은 표준 macOS 계정에서 항상 있지만 방어적으로 다룬다.)

- [ ] **Step 2: `FavoritesListView` body에 섹션을 얹는다**

기존:

```swift
            List {
            ForEach(appState.favorites) { favorite in
```

교체:

```swift
            List {
            ForEach(defaultLocations()) { location in
                Label(location.name, systemImage: location.icon)
                    .onTapGesture {
                        appState.openFolder(at: location.url)
                    }
            }
            if !defaultLocations().isEmpty {
                Divider()
            }
            ForEach(appState.favorites) { favorite in
```

- [ ] **Step 3: 빈 상태 안내가 기본 위치와 안 겹치는지 확인**

`.overlay { if appState.favorites.isEmpty { ContentUnavailableView(...) } }` 블록은 그대로 둔다 — 기본 위치는 항상 최소 1개 이상 있어 리스트 자체는 비지 않으므로 `overlay`는 즐겨찾기가 없을 때도 정상 표시된다(리스트 위에 겹쳐 그려짐, 기존 동작 유지 — SwiftUI `List` 위 `overlay`는 리스트 내용과 별개 레이어).

- [ ] **Step 4: 빌드 확인**

Run: `swift build` → 경고 0.
Run: `swift test` → 실패 0 (이 태스크는 신규 테스트 없음).

- [ ] **Step 5: 커밋**

`git commit -m "빠른 이동(3/4): 사이드바에 기본 위치(홈·데스크탑·다운로드·문서) 고정 표시"`

---

## Task 4: 등록 토글 + `QuickMoveSheet` + 트리거 배선

**Files:**
- Create: `Sources/Views/QuickMoveSheet.swift`
- Modify: `Sources/App/AppState.swift`, `Sources/Views/SidebarView.swift`, `Sources/Views/LibraryView.swift`, `Sources/Views/BatchSelectionMenu.swift`, `Sources/Views/ContentView.swift`, `Sources/App/CmdMDApp.swift`
- Test: `Tests/CmdMDTests/AppQuickMoveTests.swift`에 추가

**Interfaces:**
- Consumes: Task 1(`quickMoveFolders`·등록/해제), Task 2(`.quickMove` 단축키), Task 3(기본 위치 행 — 우클릭 메뉴 추가 대상)
- Produces:
  - `AppState.showQuickMove: Bool`
  - `AppState.quickMoveTargets: [URL]`
  - `AppState.promptQuickMove(urls: [URL]? = nil)`

- [ ] **Step 1: 실패하는 테스트를 추가한다**

```swift
    func test빠른이동요청하면대상과시트상태가세팅된다() {
        appState.fileSelection = [folder]
        appState.promptQuickMove()
        XCTAssertTrue(appState.showQuickMove)
        XCTAssertEqual(appState.quickMoveTargets, [folder])
    }

    func test선택이비어있으면빠른이동요청은무시된다() {
        appState.fileSelection = []
        appState.promptQuickMove()
        XCTAssertFalse(appState.showQuickMove)
    }

    func test목적지선택하면기존배치이동을탄다() async {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickmove-dest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)

        appState.promptQuickMove(urls: [file])
        _ = await appState.performBatchMove(urls: appState.quickMoveTargets, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppQuickMoveTests`
Expected: `type 'AppState' has no member 'showQuickMove'` 등.

- [ ] **Step 3: `AppState`에 상태·함수를 추가한다**

`showSendToVault` 선언 근처(다른 `show*` 플래그 그룹)에 추가:

```swift
    var showQuickMove: Bool = false
    var quickMoveTargets: [URL] = []
```

`addToFavorites`/`removeFromFavorites` 근처, 이번 태스크의 새 Quick Move 섹션에 추가:

```swift
    /// "빠른 이동…" — 선택 파일을 등록된 목적지 목록에서 고르게 한다. urls nil이면 현재 선택.
    func promptQuickMove(urls: [URL]? = nil) {
        let targets = urls ?? Array(fileSelection)
        guard !targets.isEmpty else { return }
        quickMoveTargets = targets
        showQuickMove = true
    }
```

- [ ] **Step 4: `QuickMoveSheet` 화면을 만든다**

`Sources/Views/QuickMoveSheet.swift`:

```swift
import SwiftUI

/// "빠른 이동…" 시트 — 등록된 목적지 폴더 클릭 시 즉시 이동(스펙 §4.3).
/// 실제 이동은 F1b가 만든 `performBatchMove`(로그+되돌리기 포함)를 그대로 쓴다.
struct QuickMoveSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("빠른 이동")
                    .font(.headline)
                Spacer()
                Text("\(appState.quickMoveTargets.count)개 항목")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if appState.quickMoveFolders.isEmpty {
                ContentUnavailableView {
                    Label("등록된 폴더가 없습니다", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("폴더에서 우클릭 → \"빠른 이동 목록에 추가\"로 등록하세요")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(appState.quickMoveFolders) { entry in
                    Button {
                        move(to: entry.url)
                    } label: {
                        Label(entry.url.lastPathComponent, systemImage: "folder")
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button("다른 폴더로 이동…") {
                    dismiss()
                    appState.promptBatchMove(urls: appState.quickMoveTargets)
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
            }
            .padding()
        }
        .frame(width: 340, height: 360)
    }

    private func move(to destination: URL) {
        let targets = appState.quickMoveTargets
        dismiss()
        Task { @MainActor in
            await appState.performBatchMove(urls: targets, to: destination)
        }
    }
}
```

- [ ] **Step 5: 시트를 배선한다**

`ContentView.swift`의 `.sheet(isPresented: $state.showFileOpsHistory) { FileOpsHistoryView() }` 다음에 추가:

```swift
        .sheet(isPresented: $state.showQuickMove) {
            QuickMoveSheet()
        }
```

- [ ] **Step 6: File 메뉴 + 단축키를 배선한다**

`CmdMDApp.swift`의 "정보 보기" 버튼 다음(`.appShortcut(appState.keyBinding(for: .fileInfo))` 바로 뒤)에 추가:

```swift

                Button("빠른 이동…") {
                    appState.promptQuickMove()
                }
                .appShortcut(appState.keyBinding(for: .quickMove))
```

- [ ] **Step 7: 우클릭 메뉴에 "빠른 이동…"과 등록 토글을 추가한다**

`BatchSelectionMenu.swift`, "폴더로 이동…" 버튼 다음:

```swift
        Button {
            appState.promptQuickMove(urls: targets)
        } label: {
            Label("빠른 이동…", systemImage: "bolt.badge.a")
        }
```

`SidebarView.swift`의 `FileTreeContextMenu.singleItemMenu`, "정보 보기" 버튼 다음:

```swift
        Button {
            appState.promptQuickMove(urls: [item.url])
        } label: {
            Label("빠른 이동…", systemImage: "bolt.badge.a")
        }
```

같은 파일 같은 뷰, 폴더일 때만(`if item.isDirectory { ... }` 블록 — "Send Folder to Vault…" 버튼 다음)에 추가:

```swift
            if appState.isQuickMoveFolder(item.url) {
                Button {
                    if let entry = appState.quickMoveFolders.first(where: { $0.url == item.url }) {
                        appState.removeFromQuickMoveFolders(entry)
                    }
                } label: {
                    Label("빠른 이동 목록에서 제거", systemImage: "bolt.slash")
                }
            } else {
                Button {
                    appState.addToQuickMoveFolders(item.url)
                } label: {
                    Label("빠른 이동 목록에 추가", systemImage: "bolt")
                }
            }
```

`LibraryView.swift`의 `LibraryCellContextMenu.singleItemMenu`, "정보 보기" 버튼 다음에 "빠른 이동…" 버튼(위와 동일 코드), `if item.isDirectory { ... }` 블록 안에 위와 동일한 등록 토글을 추가한다.

`SidebarView.swift`의 `FavoriteRow` 컨텍스트 메뉴(`isFavorited` 분기 있는 곳)에도 같은 등록 토글을 추가한다 — 즐겨찾기에 이미 등록한 폴더를 빠른 이동에도 등록하고 싶을 수 있으므로.

기본 위치 행(`DefaultLocation`, Task 3)에도 우클릭 메뉴를 추가한다 — `Label(location.name, ...)` 뷰에 `.contextMenu { ... }`를 달아 동일한 등록 토글(항상 폴더이므로 `if item.isDirectory` 분기 불필요)만 넣는다.

- [ ] **Step 8: 통과 확인 + 전체 회귀**

Run: `swift test --filter AppQuickMoveTests` → 10개 통과
Run: `swift build` → 경고 0.
Run: `swift test` → 실패 0.

- [ ] **Step 9: 커밋**

`git commit -m "빠른 이동(4/4): 등록 토글 + QuickMoveSheet + 단축키·메뉴 배선"`

---

## Task 5: 전체 재점검 + 수동 스모크 체크리스트

조각 A 관례(마지막 전체 재점검)를 따른다. 새 코드 없음 — 문서화 + 확인만.

- [ ] **Step 1: 이어붙임 결함 재검사**

다음을 손으로 다시 읽고 확인한다(조각 A 사후 재검사에서 발견한 유형과 동일한 함정 위주):

- `QuickMoveSheet`에서 이동 후 목록이 자동 갱신되는가(사이드바 트리·라이브러리) — `performBatchMove`가 기존에 처리하던 경로 그대로인지 재확인.
- 빠른 이동 대상이 이미 목적지 폴더 안에 있을 때 `performBatchMove`의 "제자리 이동 skip" 로직이 조용히 무시하는지(기존 동작) — 사용자에게 아무 피드백 없이 닫히는 건 아닌지 확인, 필요하면 토스트 추가.
- `DefaultLocation` 우클릭 메뉴에서 등록한 항목이 즐겨찾기 목록에는 안 나타나는지(별도 저장소 — 혼동 방지 재확인).
- 다중 선택 상태에서 단축키(⌥⌘M)를 눌렀을 때 `fileSelection` 전체가 대상이 되는지.

- [ ] **Step 2: 수동 스모크 (자동 테스트로는 원리상 불가)**

- [ ] 사이드바 Favorites 탭에 기본 위치 4개(홈·데스크탑·다운로드·문서) 표시, 클릭 시 해당 폴더로 전환
- [ ] 폴더 우클릭 → "빠른 이동 목록에 추가" → 다시 우클릭하면 "제거"로 바뀜
- [ ] `⌥⌘M`으로 파일 선택 후 시트 뜸, 등록된 폴더 클릭 시 실제 이동 + 파일 작업 기록에서 되돌리기 가능
- [ ] 목록이 비어있을 때 안내문 + "다른 폴더로 이동…" 버튼으로 여전히 이동 가능
- [ ] 라이브러리 화면 폴더 셀에서도 등록 토글·빠른 이동 동일하게 동작
- [ ] 기존 "폴더로 이동…"(다중 선택 메뉴, NSOpenPanel)이 그대로 동작(회귀 없음)

- [ ] **Step 3: 최종 커밋 + PRD 갱신**

`CmdMD-fork_prd.md`에 완료 기록 추가(조각 A 완료 기록과 같은 형식), `git commit -m "빠른 이동: 전체 재점검 완료 + PRD 기록"`.

---

## 이번에 하지 않을 것

- 최근 이동한 폴더 자동 기억 — 범위 밖.
- C(두 폴더 나란히 보기)·E(폴더 전환 매끄럽게) — 각각 별도 조각.
- 기존 "폴더로 이동…"(NSOpenPanel) 제거 — 그대로 유지.
- GitHub 릴리스 발행 — 이 계획 완료 후 별도 승인 절차(조각 A와 동일).
