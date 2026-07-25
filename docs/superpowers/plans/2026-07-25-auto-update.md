# 앱 내 자동 업데이트 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 상태 표시줄의 업데이트 알약을 누르면 앱이 직접 새 버전을 받아 검증하고 교체한 뒤, 재시작 여부를 묻는다.

**Architecture:** 순수 헬퍼(자산 URL·체크섬 파싱·오류 문구) → 파일시스템 교체기(원복 보장) → 오케스트레이터(actor, 네트워크·검증 경계는 프로토콜로 주입) → `AppState` 배선·UI 순으로 쌓는다. 기존 `checkForUpdates`·상태 표시줄 알약·About 버튼을 재사용하고 새 화면은 만들지 않는다.

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit. `CryptoKit`(SHA-256), `Foundation`(URLSession, FileManager), `Process`(`ditto`, `codesign`, `open`). **새 패키지 의존성 0.**

**Spec:** `docs/superpowers/specs/2026-07-25-auto-update-design.md`

## Global Constraints

- **비샌드박스 유지** — 샌드박스로 바꾸면 `Process` 호출이 막힌다.
- **새 패키지 의존성 0** — 시스템 프레임워크만 쓴다.
- 코드 주석·커밋 메시지는 **한국어**. '박다/박는다/박았다' 표현 금지.
- 사용자에게 보이는 오류·상태 문구는 **한국어**.
- **삭제 금지** — 옛 앱 번들은 `trashItem`(휴지통)으로 보낸다. `removeItem`으로 지우지 않는다.
- 신규 기능은 **별도 파일**로 분리한다(업스트림 머지 용이).
- 각 Task 전후로 `swift test`를 돌려 기존 테스트(814개 = XCTest 796 + Swift Testing 18)가 깨지지 않는지 확인한다.
- 릴리스 저장소는 **포크**(`learn-slowly/cmd-docu`)다. 원작자 저장소가 아니다.
- 자산 이름은 `cmdALL-macos.zip`, 체크섬 파일은 `SHA256SUMS.txt`(형식: `<64자리 hex>␣␣<파일명>`, 실측 확인).

## 계획 단계에서의 스펙 대비 조정 2건

### 조정 1 — 재시작 방식(스펙 §5.6 강화)

스펙은 "`open -n`을 예약 실행하고 `NSApp.terminate`"라고 적었다. 그 순서면 **저장 확인에서
사용자가 취소했을 때 인스턴스가 두 개**가 된다(기존 `applicationShouldTerminate`가
`.terminateCancel`을 돌려줄 수 있다 — `CmdMDApp.swift:447`). 대신 `pendingRelaunchBundleURL`만
세우고, 종료가 실제로 진행될 때 부르는 `applicationWillTerminate`에서 `open -n`을 띄운다.

### 조정 2 — `isVersion` 이동 취소

스펙 §5.4는 `AppState.isVersion`을 `UpdateAssets`로 옮기라고 적었다. **옮기지 않는다.**
설치기는 버전 *비교*가 필요 없고 받은 번들의 버전이 기대값과 *같은지*만 확인하면 되므로(문자열
동등 비교), 이동은 YAGNI이고 기존 호출부를 건드리는 위험만 남는다. 나머지 스펙은 그대로 따른다.

---

### Task 1: 순수 모델·헬퍼 (`UpdateProgress`, `UpdateInstallError`, `UpdateAssets`)

**Files:**
- Create: `Sources/Models/UpdateProgress.swift`
- Create: `Sources/Services/UpdateAssets.swift`
- Test: `Tests/CmdMDTests/UpdateAssetsTests.swift`

**Interfaces:**
- Consumes: 없음(첫 태스크)
- Produces:
  - `enum UpdateProgress: Equatable { case idle, downloading(fraction: Double), verifying, installing, readyToRelaunch, failed(String) }`
  - `enum UpdateInstallError: Error, Equatable { case noWritePermission(path: String), downloadFailed(String), checksumMismatch(expected: String, actual: String), unpackFailed(String), bundleVerificationFailed(String), replaceFailed(String), replaceFailedBackupLeft(backupPath: String) }`
  - `enum UpdateAssets { static let assetName: String; static func assetURL(tag: String) -> URL; static func sumsURL(tag: String) -> URL; static func expectedHash(fromSums: String, assetName: String) -> String?; static func message(for: UpdateInstallError) -> String }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/UpdateAssetsTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 업데이트 자산 URL 조립·체크섬 파싱·오류 문구(순수 헬퍼).
final class UpdateAssetsTests: XCTestCase {

    func testAssetAndSumsURLsUseGivenTag() {
        XCTAssertEqual(UpdateAssets.assetURL(tag: "v0.9.404").absoluteString,
                       "https://github.com/learn-slowly/cmd-docu/releases/download/v0.9.404/cmdALL-macos.zip")
        XCTAssertEqual(UpdateAssets.sumsURL(tag: "v0.9.404").absoluteString,
                       "https://github.com/learn-slowly/cmd-docu/releases/download/v0.9.404/SHA256SUMS.txt")
    }

    /// 실제 릴리스 파일 형식: "<64 hex>␣␣<파일명>" 두 줄(zip, dmg).
    func testExpectedHashParsesRealFormat() {
        let sums = """
        8524db4e133a01e38304e3545902dee96d3de35febe484e4c84daa0eeb938ddc  cmdALL-macos.zip
        906bf1d92f085116302ff3b4ba11c508357dc23dca5881992d1d923a0f216b9c  cmdALL-0.9.403.dmg
        """
        XCTAssertEqual(UpdateAssets.expectedHash(fromSums: sums, assetName: "cmdALL-macos.zip"),
                       "8524db4e133a01e38304e3545902dee96d3de35febe484e4c84daa0eeb938ddc")
    }

    func testExpectedHashToleratesCRLFAndPathPrefixAndCase() {
        let sums = "ABCD1234  ./dist/cmdALL-macos.zip\r\nbeef  other.zip\r\n"
        XCTAssertEqual(UpdateAssets.expectedHash(fromSums: sums, assetName: "cmdALL-macos.zip"),
                       "abcd1234")
    }

    func testExpectedHashReturnsNilWhenAssetMissing() {
        XCTAssertNil(UpdateAssets.expectedHash(fromSums: "beef  other.zip", assetName: "cmdALL-macos.zip"))
        XCTAssertNil(UpdateAssets.expectedHash(fromSums: "", assetName: "cmdALL-macos.zip"))
    }

    /// 사용자에게 보이는 문구는 한국어이고, 케이스마다 구분된다.
    func testMessagesAreKoreanAndDistinct() {
        let errors: [UpdateInstallError] = [
            .noWritePermission(path: "/Applications"),
            .downloadFailed("timeout"),
            .checksumMismatch(expected: "a", actual: "b"),
            .unpackFailed("ditto 1"),
            .bundleVerificationFailed("codesign"),
            .replaceFailed("busy"),
            .replaceFailedBackupLeft(backupPath: "/Applications/.cmdALL-backup-1.app"),
        ]
        let messages = errors.map { UpdateAssets.message(for: $0) }
        XCTAssertEqual(Set(messages).count, errors.count, "케이스별 문구가 구분돼야 한다")
        for m in messages {
            XCTAssertFalse(m.isEmpty)
            XCTAssertTrue(m.range(of: "\\p{Hangul}", options: .regularExpression) != nil, "한국어 문구: \(m)")
        }
        // 백업이 남은 경우엔 경로를 그대로 실어 사용자가 Finder로 되돌릴 수 있어야 한다.
        XCTAssertTrue(UpdateAssets.message(for: .replaceFailedBackupLeft(backupPath: "/A/.b.app"))
            .contains("/A/.b.app"))
    }

    func testProgressEquatable() {
        XCTAssertEqual(UpdateProgress.downloading(fraction: 0.5), .downloading(fraction: 0.5))
        XCTAssertNotEqual(UpdateProgress.idle, .verifying)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter UpdateAssetsTests`
Expected: 컴파일 실패 — `cannot find 'UpdateAssets' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/Models/UpdateProgress.swift`:

```swift
import Foundation

/// 앱 내 업데이트 설치 진행 상태(스펙 §5.3). UI는 이 값만 보고 그린다.
enum UpdateProgress: Equatable {
    case idle
    case downloading(fraction: Double)
    case verifying
    case installing
    /// 교체까지 끝나고 재시작 대기. "나중에"를 골라도 이미 새 버전이 설치돼 있다.
    case readyToRelaunch
    /// 사용자에게 보일 한국어 사유.
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing: return true
        case .idle, .readyToRelaunch, .failed: return false
        }
    }
}

/// 설치 실패 사유(스펙 §7). 문구 변환은 `UpdateAssets.message(for:)`가 맡는다.
enum UpdateInstallError: Error, Equatable {
    case noWritePermission(path: String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case bundleVerificationFailed(String)
    /// 교체에 실패했지만 기존 앱은 제자리로 원복됐다.
    case replaceFailed(String)
    /// 교체·원복 모두 실패 — 기존 앱이 backupPath에 남아 있다.
    case replaceFailedBackupLeft(backupPath: String)
}
```

`Sources/Services/UpdateAssets.swift`:

```swift
import Foundation

/// 릴리스 자산 URL 조립·체크섬 파싱·오류 문구(전부 순수 — 네트워크·파일시스템 접근 없음).
enum UpdateAssets {
    /// 포크 저장소다. 원작자 저장소(CmdMD)가 아니다.
    static let repository = "learn-slowly/cmd-docu"
    static let assetName = "cmdALL-macos.zip"
    static let sumsName = "SHA256SUMS.txt"

    private static func downloadBase(tag: String) -> String {
        "https://github.com/\(repository)/releases/download/\(tag)"
    }

    static func assetURL(tag: String) -> URL {
        URL(string: "\(downloadBase(tag: tag))/\(assetName)")!
    }

    static func sumsURL(tag: String) -> URL {
        URL(string: "\(downloadBase(tag: tag))/\(sumsName)")!
    }

    /// `shasum -a 256` 형식("<hex>␣␣<파일명>")에서 대상 파일의 해시를 뽑는다.
    /// 경로 접두사(`./dist/…`)·CRLF·대소문자 차이를 허용하고, 없으면 nil.
    static func expectedHash(fromSums text: String, assetName: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let name = (String(fields[fields.count - 1]) as NSString).lastPathComponent
            if name == assetName {
                return String(fields[0]).lowercased()
            }
        }
        return nil
    }

    /// 사용자에게 보일 한국어 문구. 케이스마다 구분되게 쓴다.
    static func message(for error: UpdateInstallError) -> String {
        switch error {
        case .noWritePermission(let path):
            return "설치 위치에 쓸 수 없습니다(\(path)). 터미널 설치 스크립트를 사용해 주세요."
        case .downloadFailed:
            return "새 버전을 내려받지 못했습니다. 연결을 확인하고 다시 시도해 주세요."
        case .checksumMismatch:
            return "받은 파일 검증에 실패했습니다. 설치하지 않았습니다."
        case .unpackFailed:
            return "받은 파일을 푸는 데 실패했습니다. 설치하지 않았습니다."
        case .bundleVerificationFailed:
            return "받은 앱을 확인하지 못했습니다. 설치하지 않았습니다."
        case .replaceFailed:
            return "설치에 실패했습니다. 기존 버전은 그대로입니다."
        case .replaceFailedBackupLeft(let backupPath):
            return "설치에 실패했고 기존 앱을 되돌리지 못했습니다. 다음 위치에 있습니다: \(backupPath)"
        }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter UpdateAssetsTests`
Expected: PASS (6 tests)

- [ ] **Step 5: 전체 테스트로 회귀 확인**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests"`
Expected: 실패 0

- [ ] **Step 6: 커밋**

```bash
git add Sources/Models/UpdateProgress.swift Sources/Services/UpdateAssets.swift Tests/CmdMDTests/UpdateAssetsTests.swift
git commit -m "업데이트(1/4): 진행 상태·오류 모델과 자산 URL·체크섬 파싱 순수 헬퍼"
```

---

### Task 2: `BundleReplacer` — 원자적 교체와 원복

**Files:**
- Create: `Sources/Services/BundleReplacer.swift`
- Test: `Tests/CmdMDTests/BundleReplacerTests.swift`

**Interfaces:**
- Consumes: `UpdateInstallError` (Task 1)
- Produces: `enum BundleReplacer { static func replace(staged: URL, target: URL, fileManager: FileManager, disposeBackup: (URL) throws -> Void) throws }`
  - `disposeBackup` 기본값은 휴지통 이동. 테스트는 여기에 `removeItem`을 주입해 실제 휴지통을 더럽히지 않는다.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/BundleReplacerTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 앱 번들 교체 — 성공/실패 원복/권한 없음. 가짜 .app 디렉터리로 검증한다.
final class BundleReplacerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("replacer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        // 권한 테스트가 0555로 만들어 둔 폴더도 지울 수 있게 되돌린다.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// marker 파일 하나를 담은 가짜 .app 디렉터리를 만든다.
    @discardableResult
    private func makeApp(_ url: URL, marker: String) -> URL {
        let contents = url.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try? marker.write(to: contents.appendingPathComponent("marker.txt"),
                          atomically: true, encoding: .utf8)
        return url
    }

    private func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    func testReplacesTargetWithStagedAndDisposesBackup() throws {
        let target = makeApp(root.appendingPathComponent("cmdALL.app"), marker: "old")
        let staged = makeApp(root.appendingPathComponent("staged/cmdALL.app"), marker: "new")

        var disposed: [URL] = []
        try BundleReplacer.replace(staged: staged, target: target,
                                   fileManager: .default,
                                   disposeBackup: { disposed.append($0); try FileManager.default.removeItem(at: $0) })

        XCTAssertEqual(marker(target), "new", "target에 새 번들이 놓여야 한다")
        XCTAssertEqual(disposed.count, 1, "백업이 정확히 한 번 처분돼야 한다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged는 옮겨졌어야 한다")
    }

    /// staged가 없으면 2단계에서 실패한다 — 그때 기존 앱이 제자리로 돌아와야 한다.
    func testRestoresOriginalWhenStagedMoveFails() {
        let target = makeApp(root.appendingPathComponent("cmdALL.app"), marker: "old")
        let missingStaged = root.appendingPathComponent("nope/cmdALL.app")

        XCTAssertThrowsError(
            try BundleReplacer.replace(staged: missingStaged, target: target,
                                       fileManager: .default, disposeBackup: { _ in })
        ) { error in
            guard case UpdateInstallError.replaceFailed = error else {
                return XCTFail("replaceFailed를 기대했다: \(error)")
            }
        }
        XCTAssertEqual(marker(target), "old", "기존 앱이 원복돼야 한다")
        // 백업 잔여물이 남지 않아야 한다.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix(".cmdALL-backup-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "원복 후 백업이 남으면 안 된다: \(leftovers)")
    }

    func testFailsEarlyWhenParentNotWritable() throws {
        let target = makeApp(root.appendingPathComponent("cmdALL.app"), marker: "old")
        let staged = makeApp(root.appendingPathComponent("staged/cmdALL.app"), marker: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

        XCTAssertThrowsError(
            try BundleReplacer.replace(staged: staged, target: target,
                                       fileManager: .default, disposeBackup: { _ in })
        ) { error in
            guard case UpdateInstallError.noWritePermission = error else {
                return XCTFail("noWritePermission을 기대했다: \(error)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(marker(target), "old", "아무것도 바뀌지 않아야 한다")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter BundleReplacerTests`
Expected: 컴파일 실패 — `cannot find 'BundleReplacer' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/Services/BundleReplacer.swift`:

```swift
import Foundation

/// 앱 번들을 제자리에서 교체한다(스펙 §5.2). 실패하면 기존 번들을 원복해
/// "앱이 사라지는" 상태를 만들지 않는다. 옛 번들은 지우지 않고 휴지통으로 보낸다.
enum BundleReplacer {

    static func replace(
        staged: URL,
        target: URL,
        fileManager: FileManager = .default,
        disposeBackup: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        let parent = target.deletingLastPathComponent()

        // 0) 사전 점검 — 쓸 수 없으면 다운로드·해제를 낭비하기 전에 멈춘다.
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.noWritePermission(path: parent.path)
        }

        let backup = parent.appendingPathComponent(".cmdALL-backup-\(UUID().uuidString).app")

        // 1) 기존 → 백업. 여기서 실패하면 아무것도 바뀌지 않았다.
        do {
            try fileManager.moveItem(at: target, to: backup)
        } catch {
            throw UpdateInstallError.replaceFailed(error.localizedDescription)
        }

        // 2) 새 것 → 제자리. 실패하면 즉시 원복한다.
        do {
            try fileManager.moveItem(at: staged, to: target)
        } catch {
            let moveError = error.localizedDescription
            do {
                try fileManager.moveItem(at: backup, to: target)
            } catch {
                // 원복까지 실패 — 사용자가 Finder로 되돌릴 수 있게 경로를 알린다.
                throw UpdateInstallError.replaceFailedBackupLeft(backupPath: backup.path)
            }
            throw UpdateInstallError.replaceFailed(moveError)
        }

        // 3) 성공 — 옛 번들은 휴지통으로(삭제 금지 원칙).
        try? disposeBackup(backup)
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter BundleReplacerTests`
Expected: PASS (3 tests)

- [ ] **Step 5: 전체 테스트로 회귀 확인**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests"`
Expected: 실패 0

- [ ] **Step 6: 커밋**

```bash
git add Sources/Services/BundleReplacer.swift Tests/CmdMDTests/BundleReplacerTests.swift
git commit -m "업데이트(2/4): 앱 번들 원자적 교체기 — 실패 시 원복·옛 번들은 휴지통"
```

---

### Task 3: `UpdateInstaller` — 다운로드·체크섬·해제·번들 검증

**Files:**
- Create: `Sources/Services/UpdateInstaller.swift`
- Test: `Tests/CmdMDTests/UpdateInstallerTests.swift`

**Interfaces:**
- Consumes: `UpdateAssets`, `UpdateInstallError` (Task 1), `BundleReplacer` (Task 2)
- Produces:
  - `protocol UpdateFetching: Sendable { func downloadFile(from: URL, onProgress: @Sendable (Double) -> Void) async throws -> URL; func data(from: URL) async throws -> Data }`
  - `protocol BundleVerifying: Sendable { func verify(bundleAt: URL, expectedVersion: String) throws }`
  - `actor UpdateInstaller { init(fetcher: UpdateFetching, verifier: BundleVerifying); func install(tag: String, expectedVersion: String, targetBundle: URL, onProgress: @Sendable @escaping (UpdateProgress) -> Void) async throws }`
  - 실제 구현체: `struct URLSessionFetcher: UpdateFetching`, `struct CodesignVerifier: BundleVerifying`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/UpdateInstallerTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import CmdMD

/// 설치 오케스트레이션 — 네트워크·서명 검증은 가짜로 주입한다.
final class UpdateInstallerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// marker 하나를 담은 가짜 .app을 zip으로 만들어 (zip경로, sha256) 반환.
    private func makeZippedApp(marker: String) throws -> (zip: URL, hash: String) {
        let stage = root.appendingPathComponent("stage-\(UUID().uuidString)")
        let app = stage.appendingPathComponent("cmdALL.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try marker.write(to: app.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

        let zip = root.appendingPathComponent("payload-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                       stage.appendingPathComponent("cmdALL.app").path, zip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "테스트 zip 생성 실패")

        let digest = SHA256.hash(data: try Data(contentsOf: zip))
        return (zip, digest.map { String(format: "%02x", $0) }.joined())
    }

    private struct FakeFetcher: UpdateFetching {
        let zip: URL
        let sums: String
        func downloadFile(from url: URL, onProgress: @Sendable (Double) -> Void) async throws -> URL {
            onProgress(1.0)
            // 설치기가 옮겨 갈 수 있게 매번 사본을 준다.
            let copy = zip.deletingLastPathComponent()
                .appendingPathComponent("dl-\(UUID().uuidString).zip")
            try FileManager.default.copyItem(at: zip, to: copy)
            return copy
        }
        func data(from url: URL) async throws -> Data { Data(sums.utf8) }
    }

    private struct PassingVerifier: BundleVerifying {
        func verify(bundleAt url: URL, expectedVersion: String) throws {}
    }
    private struct FailingVerifier: BundleVerifying {
        func verify(bundleAt url: URL, expectedVersion: String) throws {
            throw UpdateInstallError.bundleVerificationFailed("가짜 실패")
        }
    }

    private func makeTarget(marker: String) -> URL {
        let target = root.appendingPathComponent("cmdALL.app")
        let contents = target.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try? marker.write(to: contents.appendingPathComponent("marker.txt"),
                          atomically: true, encoding: .utf8)
        return target
    }

    private func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    func testInstallsWhenChecksumMatches() async throws {
        let (zip, hash) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "\(hash)  cmdALL-macos.zip"),
            verifier: PassingVerifier()
        )

        var seen: [UpdateProgress] = []
        try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                    targetBundle: target) { seen.append($0) }

        XCTAssertEqual(marker(target), "new", "새 번들로 교체돼야 한다")
        XCTAssertTrue(seen.contains(.verifying), "검증 단계를 보고해야 한다: \(seen)")
        XCTAssertTrue(seen.contains(.installing), "설치 단계를 보고해야 한다: \(seen)")
    }

    func testRejectsChecksumMismatchWithoutTouchingTarget() async throws {
        let (zip, _) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "deadbeef  cmdALL-macos.zip"),
            verifier: PassingVerifier()
        )

        do {
            try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                        targetBundle: target) { _ in }
            XCTFail("checksumMismatch를 기대했다")
        } catch UpdateInstallError.checksumMismatch {
            // 기대한 경로
        }
        XCTAssertEqual(marker(target), "old", "검증 실패 시 기존 앱이 그대로여야 한다")
    }

    func testRejectsWhenBundleVerificationFails() async throws {
        let (zip, hash) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "\(hash)  cmdALL-macos.zip"),
            verifier: FailingVerifier()
        )

        do {
            try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                        targetBundle: target) { _ in }
            XCTFail("bundleVerificationFailed를 기대했다")
        } catch UpdateInstallError.bundleVerificationFailed {
            // 기대한 경로
        }
        XCTAssertEqual(marker(target), "old", "서명 검증 실패 시 기존 앱이 그대로여야 한다")
    }

    /// 체크섬 파일에 자산 줄이 없으면 설치하지 않는다.
    func testRejectsWhenSumsMissingAsset() async throws {
        let (zip, _) = try makeZippedApp(marker: "new")
        let target = makeTarget(marker: "old")
        let installer = UpdateInstaller(
            fetcher: FakeFetcher(zip: zip, sums: "abc  something-else.zip"),
            verifier: PassingVerifier()
        )
        do {
            try await installer.install(tag: "v9.9.9", expectedVersion: "9.9.9",
                                        targetBundle: target) { _ in }
            XCTFail("checksumMismatch를 기대했다")
        } catch UpdateInstallError.checksumMismatch {
            // 기대한 경로
        }
        XCTAssertEqual(marker(target), "old")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter UpdateInstallerTests`
Expected: 컴파일 실패 — `cannot find 'UpdateInstaller' in scope`

- [ ] **Step 3: 최소 구현**

`Sources/Services/UpdateInstaller.swift`:

```swift
import Foundation
import CryptoKit

/// 네트워크 경계 — 테스트에서 가짜로 갈아끼운다.
protocol UpdateFetching: Sendable {
    func downloadFile(from url: URL, onProgress: @Sendable (Double) -> Void) async throws -> URL
    func data(from url: URL) async throws -> Data
}

/// 번들 검증 경계(서명·버전) — 테스트에서 가짜로 갈아끼운다.
protocol BundleVerifying: Sendable {
    func verify(bundleAt url: URL, expectedVersion: String) throws
}

/// 릴리스 zip을 받아 검증하고 앱 번들을 교체한다(스펙 §5.1).
/// 화면을 모른다 — 진행 상황은 콜백으로만 알린다.
actor UpdateInstaller {
    private let fetcher: UpdateFetching
    private let verifier: BundleVerifying

    init(fetcher: UpdateFetching = URLSessionFetcher(),
         verifier: BundleVerifying = CodesignVerifier()) {
        self.fetcher = fetcher
        self.verifier = verifier
    }

    func install(
        tag: String,
        expectedVersion: String,
        targetBundle: URL,
        onProgress: @Sendable @escaping (UpdateProgress) -> Void
    ) async throws {
        let parent = targetBundle.deletingLastPathComponent()

        // 1) 사전 점검 — 쓸 수 없으면 내려받기 전에 멈춘다.
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.noWritePermission(path: parent.path)
        }

        // 교체 대상과 같은 볼륨에 작업 폴더를 둔다(다른 볼륨이면 move가 복사로 떨어진다).
        let work = parent.appendingPathComponent(".cmdALL-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 2) 다운로드
        onProgress(.downloading(fraction: 0))
        let downloaded: URL
        do {
            downloaded = try await fetcher.downloadFile(from: UpdateAssets.assetURL(tag: tag)) {
                onProgress(.downloading(fraction: $0))
            }
        } catch {
            throw UpdateInstallError.downloadFailed(error.localizedDescription)
        }

        // 3) 체크섬 검증
        onProgress(.verifying)
        let sumsText: String
        do {
            sumsText = String(decoding: try await fetcher.data(from: UpdateAssets.sumsURL(tag: tag)),
                              as: UTF8.self)
        } catch {
            throw UpdateInstallError.downloadFailed(error.localizedDescription)
        }
        let actual = try Self.sha256Hex(of: downloaded)
        let expected = UpdateAssets.expectedHash(fromSums: sumsText, assetName: UpdateAssets.assetName)
        guard let expected, expected == actual else {
            throw UpdateInstallError.checksumMismatch(expected: expected ?? "(없음)", actual: actual)
        }

        // 4) 압축 해제
        let unpacked = work.appendingPathComponent("unpacked")
        try Self.run("/usr/bin/ditto", ["-x", "-k", downloaded.path, unpacked.path],
                     failure: { UpdateInstallError.unpackFailed($0) })
        let staged = unpacked.appendingPathComponent("cmdALL.app")
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw UpdateInstallError.unpackFailed("zip 안에서 cmdALL.app을 찾지 못했습니다")
        }

        // 5) 번들 검증(서명·버전)
        try verifier.verify(bundleAt: staged, expectedVersion: expectedVersion)

        // 6) 교체
        onProgress(.installing)
        try BundleReplacer.replace(staged: staged, target: targetBundle)
    }

    // MARK: - 도우미

    /// 큰 파일도 메모리에 통째로 올리지 않도록 조각내어 해시한다.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ launchPath: String, _ arguments: [String],
                    failure: (String) -> UpdateInstallError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw failure(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(text.isEmpty ? "종료 코드 \(process.terminationStatus)" : text)
        }
    }
}

// MARK: - 실제 구현체

struct URLSessionFetcher: UpdateFetching {
    func downloadFile(from url: URL, onProgress: @Sendable (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateInstallError.downloadFailed("HTTP \(http.statusCode)")
        }
        // URLSession이 지우기 전에 우리 임시 위치로 옮긴다.
        let kept = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmdALL-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temp, to: kept)
        onProgress(1.0)
        return kept
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateInstallError.downloadFailed("HTTP \(http.statusCode)")
        }
        return data
    }
}

struct CodesignVerifier: BundleVerifying {
    func verify(bundleAt url: URL, expectedVersion: String) throws {
        // 버전이 기대와 다르면(릴리스가 교체됐다든지) 설치하지 않는다.
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            throw UpdateInstallError.bundleVerificationFailed("Info.plist를 읽지 못했습니다")
        }
        guard version == expectedVersion else {
            throw UpdateInstallError.bundleVerificationFailed("버전 불일치: \(version) ≠ \(expectedVersion)")
        }
        try UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path],
                                failure: { UpdateInstallError.bundleVerificationFailed($0) })
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter UpdateInstallerTests`
Expected: PASS (4 tests)

- [ ] **Step 5: 전체 테스트로 회귀 확인**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests"`
Expected: 실패 0

- [ ] **Step 6: 커밋**

```bash
git add Sources/Services/UpdateInstaller.swift Tests/CmdMDTests/UpdateInstallerTests.swift
git commit -m "업데이트(3/4): 다운로드·체크섬·해제·번들 검증 오케스트레이터"
```

---

### Task 4: `AppState` 배선 · UI · 재시작

**Files:**
- Modify: `Sources/App/AppState.swift` (업데이트 확인 구역: `checkForUpdates` 부근 ~697-740, 상태 프로퍼티 ~141)
- Modify: `Sources/Views/StatusBarView.swift` (`UpdateBadge`, 62-85)
- Modify: `Sources/Views/MainEditorView.swift:48` (상태 표시줄 노출 조건)
- Modify: `Sources/Views/ContentView.swift:539-560` (About 창 버튼)
- Modify: `Sources/App/CmdMDApp.swift:430-439` (`applicationWillTerminate`에서 재실행)
- Test: `Tests/CmdMDTests/AppUpdateInstallTests.swift`

**Interfaces:**
- Consumes: `UpdateProgress`, `UpdateInstallError`, `UpdateAssets` (Task 1), `UpdateInstaller` (Task 3)
- Produces: `AppState.updateProgress`, `AppState.latestTag`, `AppState.startUpdateInstall()`, `AppState.relaunchForUpdate()`, `AppState.dismissUpdateProgress()`, `AppState.pendingRelaunchBundleURL`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppUpdateInstallTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 업데이트 설치 배선 — 실제 네트워크 없이 AppState 상태 전이를 검증한다.
@MainActor
final class AppUpdateInstallTests: XCTestCase {
    var dir: URL!
    var state: AppState!

    override func setUp() async throws {
        dir = TempDataDirectory.make()
        state = AppState(dataDirectory: dir)
    }
    override func tearDown() async throws {
        TempDataDirectory.cleanup(dir)
    }

    func testInstallDoesNothingWithoutTag() async {
        state.updateAvailable = true
        state.latestTag = nil
        await state.startUpdateInstall()
        XCTAssertEqual(state.updateProgress, .idle, "태그가 없으면 시작하지 않는다")
    }

    func testSuccessfulInstallEndsInReadyToRelaunch() async {
        state.updateAvailable = true
        state.latestTag = "v9.9.9"
        state.latestVersion = "9.9.9"
        await state.startUpdateInstall(perform: { _, _, _, report in
            report(.downloading(fraction: 0.5))
            report(.installing)
        })
        XCTAssertEqual(state.updateProgress, .readyToRelaunch)
    }

    func testFailedInstallShowsKoreanMessage() async {
        state.updateAvailable = true
        state.latestTag = "v9.9.9"
        state.latestVersion = "9.9.9"
        await state.startUpdateInstall(perform: { _, _, _, _ in
            throw UpdateInstallError.checksumMismatch(expected: "a", actual: "b")
        })
        guard case .failed(let message) = state.updateProgress else {
            return XCTFail("failed를 기대했다: \(state.updateProgress)")
        }
        XCTAssertEqual(message, UpdateAssets.message(for: .checksumMismatch(expected: "a", actual: "b")))
    }

    func testDismissResetsProgressButKeepsUpdateAvailable() async {
        state.updateAvailable = true
        state.updateProgress = .failed("어떤 오류")
        state.dismissUpdateProgress()
        XCTAssertEqual(state.updateProgress, .idle)
        XCTAssertTrue(state.updateAvailable, "알약은 계속 보여야 한다")
    }

    /// 재시작은 종료가 실제로 진행될 때만 새 인스턴스를 띄운다(취소 시 두 개가 뜨면 안 된다).
    func testRelaunchOnlyArmsPendingURL() {
        XCTAssertNil(state.pendingRelaunchBundleURL)
        state.armRelaunch(bundleURL: URL(fileURLWithPath: "/Applications/cmdALL.app"))
        XCTAssertEqual(state.pendingRelaunchBundleURL?.path, "/Applications/cmdALL.app")
    }

    /// 진행률 보고는 MainActor로 건너뛰므로 완료 뒤에 도착할 수 있다.
    /// 그때 `.readyToRelaunch`를 덮어써 "설치 중"으로 되돌리면 안 된다.
    func testLateProgressReportDoesNotClobberReadyState() async {
        final class Box: @unchecked Sendable { var report: (@Sendable (UpdateProgress) -> Void)? }
        let box = Box()

        state.updateAvailable = true
        state.latestTag = "v9.9.9"
        state.latestVersion = "9.9.9"
        await state.startUpdateInstall(perform: { _, _, _, report in box.report = report })
        XCTAssertEqual(state.updateProgress, .readyToRelaunch)

        box.report?(.downloading(fraction: 0.1))   // 늦게 도착한 보고
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(state.updateProgress, .readyToRelaunch, "완료 후 보고는 무시돼야 한다")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppUpdateInstallTests`
Expected: 컴파일 실패 — `value of type 'AppState' has no member 'updateProgress'`

- [ ] **Step 3: `AppState` 구현**

`Sources/App/AppState.swift` — 상태 프로퍼티(기존 `updateAvailable` 옆, ~141):

```swift
    var updateProgress: UpdateProgress = .idle
    /// GitHub 릴리스 태그 원본("v0.9.404"). 자산 URL 조립에 쓴다.
    var latestTag: String?
    /// 종료가 실제로 진행될 때 재실행할 번들. AppDelegate가 읽는다.
    var pendingRelaunchBundleURL: URL?
    /// 진행 중인 설치의 식별자. 완료 후 늦게 도착하는 진행률 보고를 버리는 데 쓴다.
    private var installToken: UUID?
```

`checkForUpdates` 안, `latestVersion` 대입 옆에 한 줄 추가:

```swift
                latestTag = tag
```

업데이트 확인 구역 끝에 추가:

```swift
    /// 설치 절차의 주입 지점. 기본값은 실제 `UpdateInstaller`.
    typealias UpdateInstallWork = @Sendable (_ tag: String, _ version: String, _ bundle: URL,
                                             _ report: @Sendable @escaping (UpdateProgress) -> Void) async throws -> Void

    /// 알약·About 버튼이 부르는 진입점. 받기→검증→교체까지 하고 재시작 대기 상태로 둔다.
    ///
    /// `installToken`이 필요한 이유: 진행률 보고는 설치기(actor)에서 오므로 MainActor로
    /// 건너뛰어야 하는데, 그 사이 설치가 끝나면 **늦게 도착한 보고가 `.readyToRelaunch`를
    /// 덮어써 "설치 중"으로 되돌린다**. 토큰이 다르면 무시한다.
    @MainActor
    func startUpdateInstall(perform: UpdateInstallWork? = nil) async {
        guard !updateProgress.isBusy else { return }
        guard let tag = latestTag, let version = latestVersion else { return }

        let bundle = Bundle.main.bundleURL
        let token = UUID()
        installToken = token
        updateProgress = .downloading(fraction: 0)

        let work: UpdateInstallWork = perform ?? { tag, version, bundle, report in
            let installer = UpdateInstaller()
            try await installer.install(tag: tag, expectedVersion: version,
                                        targetBundle: bundle, onProgress: report)
        }

        do {
            try await work(tag, version, bundle) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.installToken == token else { return }
                    self.updateProgress = progress
                }
            }
            installToken = nil          // 이후 도착하는 보고는 버린다
            updateProgress = .readyToRelaunch
        } catch let error as UpdateInstallError {
            installToken = nil
            updateProgress = .failed(UpdateAssets.message(for: error))
        } catch {
            installToken = nil
            updateProgress = .failed(UpdateAssets.message(for: .downloadFailed(error.localizedDescription)))
        }
    }

    /// "나중에"·오류 닫기 — 알약(updateAvailable)은 그대로 둔다.
    func dismissUpdateProgress() {
        updateProgress = .idle
    }

    /// 종료 시 재실행하도록 예약만 한다. 실제 실행은 applicationWillTerminate가 한다 —
    /// 저장 확인에서 취소하면 종료가 취소되므로, 미리 띄우면 인스턴스가 두 개가 된다.
    func armRelaunch(bundleURL: URL) {
        pendingRelaunchBundleURL = bundleURL
    }

    /// "지금 다시 시작". 저장 안 된 문서 확인은 기존 applicationShouldTerminate가 맡는다.
    func relaunchForUpdate() {
        armRelaunch(bundleURL: Bundle.main.bundleURL)
        NSApp.terminate(nil)
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter AppUpdateInstallTests`
Expected: PASS (5 tests)

- [ ] **Step 5: 재실행 훅 배선**

`Sources/App/CmdMDApp.swift` — `applicationWillTerminate`(430) 안, 모니터 제거 뒤에 추가:

```swift
        // 업데이트 후 "지금 다시 시작" — 종료가 실제로 진행될 때만 새 인스턴스를 띄운다.
        if let bundle = AppState.shared?.pendingRelaunchBundleURL {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundle.path]
            try? process.run()
        }
```

- [ ] **Step 6: 상태 표시줄 알약 교체**

`Sources/Views/StatusBarView.swift` — `UpdateBadge`(62-85) 전체를 교체:

```swift
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        switch appState.updateProgress {
        case .idle:
            installButton
        case .downloading(let fraction):
            label("받는 중 \(Int(fraction * 100))%")
        case .verifying:
            label("검증 중")
        case .installing:
            label("설치 중")
        case .readyToRelaunch:
            HStack(spacing: 6) {
                Text("새 버전 준비됨")
                    .font(.system(size: 11, weight: .medium))
                Button("지금 다시 시작") { appState.relaunchForUpdate() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                Button("나중에") { appState.dismissUpdateProgress() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color.cmdsAccent)
        case .failed(let message):
            Button { appState.dismissUpdateProgress() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(message)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help(message)
        }
    }

    private var installButton: some View {
        Button {
            Task { await appState.startUpdateInstall() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10))
                Text(appState.latestVersion.map { "Update \($0)" } ?? "Update available")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.cmdsAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isHovering ? Color.cmdsAccentSoft : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("새 버전이 있습니다 — 눌러서 설치")
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.cmdsAccent)
    }
```

- [ ] **Step 7: 상태 표시줄 노출 조건 수정**

`Sources/Views/MainEditorView.swift:48` — 문서가 없어도 상태 표시줄이 보이게 한다.
`StatusBarView`는 내부에서 이미 `if let document = appState.currentDocument`로 문서 의존 항목을
가리므로 조건만 덜어내면 된다.

```swift
        if appState.settings.showStatusBar {
            StatusBarView()
        }
```

- [ ] **Step 8: About 창 버튼 교체**

`Sources/Views/ContentView.swift:540-547` — 브라우저 열기 대신 같은 진입점을 쓴다.

```swift
            if appState.updateAvailable {
                if case .idle = appState.updateProgress {
                    Button {
                        Task { await appState.startUpdateInstall() }
                    } label: {
                        Label("Update available: \(appState.latestVersion ?? "")",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cmdsAccent)
                } else {
                    UpdateBadge()
                }
            } else {
```

- [ ] **Step 9: 빌드·전체 테스트**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed [0-9]+ tests"`
Expected: 경고 0, 실패 0

- [ ] **Step 10: 커밋**

```bash
git add Sources/App/AppState.swift Sources/App/CmdMDApp.swift Sources/Views/StatusBarView.swift Sources/Views/MainEditorView.swift Sources/Views/ContentView.swift Tests/CmdMDTests/AppUpdateInstallTests.swift
git commit -m "업데이트(4/4): AppState 배선·상태 표시줄 알약 설치 동작·재시작 예약"
```

---

## 수동 스모크 (원리상 자동 불가 — 구현 후 사용자와 함께)

1. 0.9.404를 패키징·릴리스한 뒤, 0.9.403 설치본에서 알약이 뜨는지
2. 알약을 눌러 받기 진행률 → 검증 → 설치 → "새 버전 준비됨"까지
3. **Gatekeeper 차단 화면이 뜨지 않는지**(이 설계의 핵심 전제)
4. "지금 다시 시작" → 새 버전으로 뜨고 탭이 복원되는지
5. 저장 안 된 문서가 있을 때 "지금 다시 시작" → 저장 확인이 뜨고, **취소하면 앱이 그대로 남고
   인스턴스가 두 개가 되지 않는지**
6. "나중에" → 앱을 직접 껐다 켜면 새 버전인지
7. PDF 탭에서도 알약이 보이는지(Step 7 수정 확인)
