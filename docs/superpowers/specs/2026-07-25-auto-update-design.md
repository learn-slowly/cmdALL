# 앱 내 자동 업데이트 설계 (2026-07-25)

## 1. 배경

현재 `Check for Updates`는 **알림까지만** 한다. `AppState.checkForUpdates`가 GitHub Releases API를
6시간 스로틀로 조회해 `updateAvailable`·`latestVersion`·`updateURL`을 세우고, 상태 표시줄 알약과
About 창 버튼이 그걸 눌러 **브라우저로 릴리스 페이지를 연다**. 실제 설치는 사용자가 dmg/zip을
내려받아 손으로 한다.

그 손 설치가 실사고를 냈다(2026-07-25). 사용자가 Safari로 `cmdALL-0.9.403.dmg`를 받아 설치하자
Gatekeeper가 "Apple은 악성 코드가 없음을 확인할 수 없습니다"로 차단하고 **기본 버튼이 "휴지통으로
이동"** 이었다. 앱이 ad-hoc 서명(비공증)이라 브라우저 다운로드에 quarantine이 붙기 때문이다.
설상가상 README가 안내하던 `xattr -dr`은 번들 리소스가 0444로 배포돼 Permission denied로 실패했다
(별건으로 수정 완료 — `package_app.sh`에 `chmod -R u+w`, README 재작성).

## 2. 결정적 실측 — 앱 내 다운로드에는 quarantine이 붙지 않는다

설계의 전제가 되는 사실을 프로세스 밖 프로브로 확인했다.

- ad-hoc 서명·비샌드박스·`LSFileQuarantineEnabled` 미설정인 **앱 번들** 안에서
  `URLSession.downloadTask`로 GitHub 릴리스 자산을 받았다.
- 결과 xattr: `com.apple.provenance`만 존재. **`com.apple.quarantine` 없음.**

즉 앱이 스스로 받아 설치하면 Gatekeeper 차단 화면이 **아예 뜨지 않는다**. 기존 CLAUDE.md가 A안에
달아둔 "quarantine 자동해제 편법 필요"라는 단서는 사실이 아니며, 이 문서로 정정한다.

부수 실측(같은 세션): 실행 중인 `/Applications/cmdALL.app`을 `rm -rf` 후 `ditto`로 교체해도 실행
중인 프로세스는 그대로 살아 있었다. 자기 자신 교체가 가능하다.

## 3. 사용자 결정 사항

| 항목 | 결정 |
|---|---|
| 자동화 수준 | **버튼 하나로 설치** (완전 자동 아님) |
| 재시작 | 설치 후 **"지금 다시 시작 / 나중에"** 를 그때 고른다 |
| 알림 방식 | **조용한 표시** (대화상자 없음) — 기존 상태 표시줄 알약 재사용 |

## 4. 사용자 흐름

```
6시간마다 조용히 확인 (기존 그대로)
        │
        ▼
새 버전 있음 → 상태 표시줄에 "⬇ Update 0.9.404" 알약 (기존 UI)
        │
        │ 클릭 (지금은 브라우저 열기 → 앞으로는 설치 시작)
        ▼
받는 중 (진행률 %) → 검증 중 → 설치 중
        │
        ├─ 성공 → "새 버전이 준비됐습니다  [지금 다시 시작] [나중에]"
        │            └ 나중에 → 다음 실행 때 새 버전
        └─ 실패 → 원래 앱 그대로 복구 + 실패 사유 안내(+ 릴리스 페이지 열기 폴백)
```

## 5. 구성 요소

신규는 전부 별도 파일로 둔다(업스트림 머지 용이·단위 테스트 용이).

### 5.1 `Sources/Services/UpdateInstaller.swift` (신규, actor)

부수효과를 담당한다. 화면을 모른다.

```
func install(version: String,
             assetURL: URL,
             sumsURL: URL,
             bundleURL: URL,
             onProgress: @Sendable (Double) -> Void) async throws
```

성공하면 그냥 반환한다(교체 완료). 실패는 전부 `UpdateInstallError`로 던진다 — §7의 표가
그대로 케이스가 된다:

```
enum UpdateInstallError: Error, Equatable {
    case noWritePermission(path: String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case bundleVerificationFailed(String)   // 서명 또는 버전 불일치
    case replaceFailed(String)              // 원복 성공
    case replaceFailedBackupLeft(backupPath: String)   // 원복도 실패
}
```

`AppState`가 이걸 받아 한국어 문구로 옮겨 `.failed`에 싣는다(문구 매핑은 순수 함수로 두어 테스트).

절차:

1. **사전 점검** — `bundleURL`의 부모 디렉터리에 쓰기 권한이 있는지(`FileManager.isWritableFile`).
   없으면 `.noWritePermission`으로 즉시 실패(다운로드 낭비 금지).
2. **다운로드** — `URLSession.download`로 zip을 임시 디렉터리에 받는다. 진행률은
   `URLSessionTaskDelegate`로 보고. 타임아웃 300초.
3. **체크섬 검증** — 같은 릴리스의 `SHA256SUMS.txt`를 받아 `cmdALL-macos.zip` 줄의 해시와
   받은 파일의 SHA-256(CryptoKit)을 대조. 불일치면 `.checksumMismatch`.
4. **압축 해제** — `ditto -x -k`(Process)로 임시 디렉터리에 푼다. `.app`이 없으면 실패.
5. **번들 검증** — 푼 앱의 `CFBundleShortVersionString`이 기대 버전과 같은지, `codesign -v`가
   통과하는지 확인. 실패면 설치하지 않는다.
6. **원자적 교체** — 5.2 참조.

임시 디렉터리는 **교체 대상과 같은 볼륨**에 만든다(`bundleURL` 부모 아래 `.cmdALL-update-<uuid>`).
다른 볼륨이면 `moveItem`이 복사로 떨어져 원자성이 깨진다.

### 5.2 교체 절차(되돌릴 수 있게)

```
old  = /Applications/cmdALL.app
stage= /Applications/.cmdALL-update-<uuid>/cmdALL.app   (검증 끝난 새 앱)
back = /Applications/.cmdALL-backup-<uuid>.app

1) move(old  → back)     실패 → 중단, 아무것도 안 바뀜
2) move(stage → old)     실패 → move(back → old)로 원복 후 실패 보고
3) 성공 → back을 휴지통으로(삭제 아님), 임시 디렉터리 정리
```

2번이 실패한 뒤 원복까지 실패하는 최악의 경우에만 앱이 제자리에 없다. 그때는 `back` 경로를
오류 메시지에 그대로 실어 사용자가 Finder로 되돌릴 수 있게 한다.

**삭제 금지 원칙**(프로젝트 규칙)에 맞춰 옛 번들은 `trashItem`으로 보낸다.

### 5.3 `Sources/Models/UpdateProgress.swift` (신규, 순수)

```
enum UpdateProgress: Equatable {
    case idle
    case downloading(fraction: Double)
    case verifying
    case installing
    case readyToRelaunch          // 설치 끝, 재시작 대기
    case failed(String)           // 한국어 사유
}
```

### 5.4 `Sources/Services/UpdateAssets.swift` (신규, 순수 헬퍼)

테스트 가능한 순수 함수만 모은다.

- `assetURL(tag:)` / `sumsURL(tag:)` — 릴리스 태그로 자산 URL 조립
- `expectedHash(fromSums:assetName:)` — `SHA256SUMS.txt` 본문 파싱(공백·경로 접두사·CRLF 허용,
  대상 파일명이 없으면 nil)
- `isVersion(_:newerThan:)` — 기존 `AppState.isVersion`(static)을 **본문 그대로** 옮긴다.
  `checkForUpdates`는 호출처만 바뀌고 동작은 불변이며, 기존 테스트가 있으면 그대로 통과해야 한다.
  (§5.5의 "기존 `checkForUpdates`를 그대로 둔다"는 **동작**이 불변이라는 뜻이지, 이 헬퍼 이동까지
  금지한다는 뜻이 아니다.)

### 5.5 `AppState` (기존 파일, 가산만)

- `var updateProgress: UpdateProgress = .idle`
- `func startUpdateInstall()` — 진행 중이면 무시. `UpdateInstaller`를 호출하고 진행률을 반영.
  성공 시 `.readyToRelaunch`.
- `func relaunchForUpdate()` — 5.6.
- `func dismissUpdateBanner()` — "나중에" 선택 시 `.idle`로(알약은 계속 새 버전 표시).

기존 `checkForUpdates`·`updateAvailable`·`latestVersion`·`updateURL`은 **그대로 둔다**.
`updateURL`은 설치 실패 시 폴백(릴리스 페이지 열기)으로 계속 쓴다.

### 5.6 재시작

"지금 다시 시작"을 누르면:

1. 저장 안 된 문서 확인 — **기존 종료 확인 경로를 재사용**한다(`⌘Q` 때 쓰는 dirty 확인).
   취소하면 재시작하지 않고 `.readyToRelaunch` 유지.
2. `Process`로 `/usr/bin/open -n <bundleURL>`을 예약 실행하고 `NSApp.terminate(nil)`.
   열려 있던 탭은 기존 세션 복원이 되살린다.

"나중에"면 아무것도 하지 않는다. 이미 교체가 끝났으므로 다음 실행이 새 버전이다.

## 6. UI 변경

기존 UI를 최대한 재사용한다. 새 화면은 만들지 않는다.

- **`StatusBarView`의 업데이트 알약** — 동작을 `NSWorkspace.open(updateURL)` → `startUpdateInstall()`
  로 교체. 진행 중에는 같은 자리에서 라벨이 바뀐다(`받는 중 42%` → `검증 중` → `설치 중`).
  `.readyToRelaunch`면 `[지금 다시 시작] [나중에]` 두 버튼.
- **상태 표시줄 노출 조건 수정** — 현재 `MainEditorView:48`이
  `showStatusBar && currentDocument != nil`이라 **PDF·이미지·미디어 탭에선 상태 표시줄 자체가
  숨겨져 알약도 안 보인다**. 업데이트 알약은 문서 종류와 무관하므로, 상태 표시줄을
  `showStatusBar`만으로 표시하고 문서 의존 항목(단어 수·커서 위치 등)만 문서가 있을 때 그리도록
  바꾼다.
- **About 창 버튼** — 같은 `startUpdateInstall()`을 부르고 같은 진행 상태를 보여준다.

## 7. 실패 처리

| 상황 | 처리 |
|---|---|
| 네트워크 실패·타임아웃 | `.failed("내려받지 못했습니다")` + 릴리스 페이지 열기 버튼 |
| 체크섬 불일치 | `.failed("파일 검증에 실패했습니다")` — 설치하지 않음 |
| 서명·버전 검증 실패 | `.failed("받은 앱을 확인하지 못했습니다")` — 설치하지 않음 |
| 쓰기 권한 없음 | `.failed("설치 위치에 쓸 수 없습니다")` + 터미널 설치 안내(`install_latest.sh`) |
| 교체 실패 후 원복 성공 | `.failed("설치에 실패했습니다 — 기존 버전 그대로입니다")` |
| 교체·원복 모두 실패 | `.failed`에 백업 경로 문자열 포함 |

모든 문구는 한국어. 진행 중 앱 종료는 막지 않는다(임시 파일만 남고 기존 앱은 무사).

## 8. 테스트 전략

**단위(자동)**

- `UpdateAssets` 순수 함수 — 자산 URL 조립, `SHA256SUMS.txt` 파싱(정상·CRLF·대상 없음·공백 변형),
  버전 비교(기존 케이스 이관).
- `UpdateInstaller`의 교체 로직 — 임시 디렉터리에 **가짜 `.app` 디렉터리**를 만들어
  ① 정상 교체 ② 2단계 실패 시 원복 ③ 쓰기 권한 없음 조기 실패를 검증한다. 네트워크·codesign은
  주입 가능한 경계로 분리해 가짜를 넣는다.
- `UpdateProgress` 상태 전이.

**수동(원리상 자동 불가)**

- 실제 릴리스에서 받아 설치 → 재시작 → 새 버전 확인
- Gatekeeper 차단 화면이 뜨지 않는지(이 설계의 핵심 전제)
- 저장 안 된 문서가 있을 때 재시작 확인 흐름

## 9. 이번에 하지 않는 것

- 완전 자동(묻지 않는 백그라운드) 설치
- Sparkle 등 외부 업데이트 프레임워크 도입 — **새 패키지 의존성 0** 원칙 유지
- delta(부분) 업데이트
- Apple Developer ID 서명·공증(연 $99) — 별도 결정 사항. 다만 이 설계는 공증이 없어도 동작하며,
  나중에 공증을 도입해도 이 코드는 그대로 쓸 수 있다.
- 다운그레이드·특정 버전 선택 설치
- 업데이트 채널(베타/정식) 분리

## 10. 영향 범위

- 신규 파일 4개(`UpdateInstaller`, `UpdateAssets`, `UpdateProgress`, 관련 테스트)
- 기존 변경: `AppState`(가산), `StatusBarView`(알약 동작·진행 표시), `MainEditorView`(상태 표시줄
  노출 조건), `ContentView`(About 버튼 동작)
- 새 패키지 의존성 0. `CryptoKit`·`Foundation`·`AppKit`은 시스템 프레임워크.
