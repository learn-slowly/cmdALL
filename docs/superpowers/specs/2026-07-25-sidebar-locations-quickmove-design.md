# D+B. 기본 위치 + 빠른 이동 (설계)

- 날짜: 2026-07-25
- 상태: 설계 승인 대기
- 상위 문서: `2026-07-25-finder-preview-direction.md`(조각 A~E 중 **D+B**, 순서 ①안의 두 번째 조각 — A 다음)
- 조각 A(빠른 파인더 못 여는 파일 미리보기)는 완료·배포 완료(v0.9.410). 이 문서는 그다음 조각.

---

## 1. 목적

`2026-07-25-finder-preview-direction.md` §1 "지금도 파인더를 열게 되는 순간" 중 두 가지를 없앤다.

- **D. 기본 위치** — 사이드바에 홈·데스크탑·다운로드·문서가 없다. 즐겨찾기에 손으로 등록해야 나타난다.
- **B. 빠른 이동** — 다른 폴더로 옮기려면 우클릭 → "폴더로 이동…" → macOS 폴더 선택 창이 뜨고 → 클릭으로 찾아 들어가야 한다. 자주 가는 곳도 매번 이 창을 연다.

두 조각을 묶는 이유: 방향 문서(§3 순서 후보 ①)에서 원래 한 조각으로 묶였고, 둘 다 "아주 작음~작음"이라 함께 진행한다. 목적지 목록은 아래 4.1처럼 **B 전용으로 사용자가 직접 등록**하는 별도 목록이라 D와 저장소는 공유하지 않는다(2026-07-25 사용자 결정).

## 2. 실측 — 지금 구조 확인

- 사이드바 "Favorites" 탭(`SidebarView.swift:651` `FavoritesListView`)은 `AppState.favorites`([`FavoriteItem`], `favorites.json`에 저장)만 보여준다. 폴더든 파일이든 사용자가 우클릭 → "Add to Favorites"로 손수 등록해야 나타난다. 기본 위치(홈·데스크탑·다운로드·문서)를 자동으로 넣는 코드는 없다(`Sources` 전체에 `desktopDirectory`·`downloadsDirectory`·`documentDirectory` 사용처 0건, 확인 완료).
- 폴더 이동은 이미 다 있다 — `AppState.promptBatchMove(urls:)`(`AppState.swift:2457`)가 `NSOpenPanel`로 목적지를 받고 `performBatchMove(urls:to:)`(`AppState.swift:2474`)가 실제 이동+짝꿍 노트 동반+로그(`fileOpsLogStore`)+되돌리기까지 처리한다. **이동 로직은 손대지 않는다.** 목적지를 받는 방식만 "창 열기" 대신 "미리 뜬 목록에서 클릭"으로 바꾼다.
- 단일 항목 우클릭 메뉴(`FileTreeContextMenu`·`LibraryCellContextMenu`)에는 지금 "폴더로 이동…"이 아예 없다(다중 선택 메뉴 `BatchSelectionMenu`에만 있음). 이번에 단일 항목에도 추가한다.
- 이미 있는 비슷한 기능 "Send to Vault…"(⇧⌘T, `sendToVault`)와 "Auto-Route"(⌃⌘T, `autoRoute`)는 **다른 기능**이다 — Claude가 노트를 읽고 PARA 폴더를 골라주는 기능(옵시디언 볼트 전용). 이번 B는 Claude 판단 없이 **사람이 직접 목록에서 고르는** 일반 파일 이동이라 이름·단축키를 겹치지 않게 분리한다.

## 3. D. 기본 위치 — 설계

- **어디에 두나**: 새 사이드바 탭을 만들지 않는다. 기존 "Favorites" 탭(`FavoritesListView`) 안에 **"기본 위치"** 섹션을 즐겨찾기 목록 **위**에 고정으로 얹는다. 사용자 요청("파인더처럼 처음부터 늘 거기 있다. 기존 즐겨찾기는 그대로 둔다")과 정확히 일치.
- **목록**: 홈(`FileManager.default.homeDirectoryForCurrentUser`) · 데스크탑(`.desktopDirectory`) · 다운로드(`.downloadsDirectory`) · 문서(`.documentDirectory`), 이 순서 고정. `FileManager.default.urls(for:in:.userDomainMask).first`로 가져온다(기존 코드베이스 관례 — `VaultService.swift:165` 등에서 이미 쓰는 패턴).
- **저장 안 함**: 매번 계산만 하는 고정 목록이라 `favorites.json` 같은 새 저장 파일 불필요. 새 모델도 불필요 — 표시용 4개 튜플(이름, 아이콘, URL)만 뷰 안에 정적으로 둔다.
- **없는 폴더는 숨김**: `FileManager.default.fileExists`로 실존 확인 후 없는 항목은 목록에서 뺀다(방어적 — 보통은 4개 다 있음).
- **동작**: 클릭 시 기존 즐겨찾기 폴더 행과 동일하게 `appState.openFolder(at:)` 호출(작업 폴더 전환). 새 동작 아님, 기존 패턴 재사용.
- **우클릭 메뉴 없음**: 즐겨찾기와 달리 "제거" 메뉴를 안 둔다(고정 위치라 뺄 수 없음 — 파인더도 동일).
- **아이콘**: 홈 `house`, 데스크탑 `menubar.dock.rectangle`, 다운로드 `arrow.down.circle`, 문서 `doc.on.doc` 정도(SF Symbols, 최종은 구현 시 확인).

## 4. B. 빠른 이동 — 설계

### 4.1 목적지 목록 — 결정 사항

`finder-preview-direction.md`가 미결로 남긴 질문("즐겨찾기 그대로 쓸지, 최근 기억할지, 따로 등록할지")에 대한 답 — **사용자 결정(2026-07-25): 따로 등록.**

> 즐겨찾기·기본 위치와 별개로, **"빠른 이동 목록"** 전용 목록을 새로 만든다. 사용자가 폴더를 우클릭해서 **"빠른 이동 목록에 추가"** 해야만 그 목록에 나타난다. 즐겨찾기에 있다고 자동으로 끼어들지 않는다 — 두 목록은 성격이 다르다(즐겨찾기="열어볼 곳", 빠른 이동="보낼 곳").

새 모델 `QuickMoveFolder`(id·url·addedAt, `FavoriteItem`과 같은 모양이지만 별도 타입) + 새 저장 `AppState.quickMoveFolders`(`quickmove-folders.json`, 기존 `favorites` 저장·로드 관례 그대로 재사용 — 존재하지 않는 경로는 로드 시 필터링).

**등록 진입점**: 폴더를 우클릭할 수 있는 모든 자리(사이드바 트리 `FileTreeContextMenu`, 즐겨찾기 목록 행, D의 기본 위치 행)에 "빠른 이동 목록에 추가" / 이미 있으면 "빠른 이동 목록에서 제거" 토글을 즐겨찾기 토글과 같은 자리에 나란히 둔다. 라이브러리 폴더 셀(`LibraryCellContextMenu`)에도 동일하게 추가(현재 그 메뉴엔 즐겨찾기 토글 자체가 없어 이번에 함께 신설).

**목록이 비어있을 때**: 팝오버에 "등록된 폴더가 없습니다 — 폴더에서 우클릭 → 빠른 이동 목록에 추가"안내 + 기존 "다른 폴더로 이동…"(NSOpenPanel) 버튼은 팝오버 안에도 그대로 노출해 처음부터 막히지 않게 한다.

### 4.2 진입점

- **단축키**: `⌥⌘M`(Option+Command+M) — 기존 단축키(§ Shortcuts.swift 전수 확인, 겹침 없음) 미사용 조합. "Send to Vault"(⇧⌘T)·"Auto-Route"(⌃⌘T)와 다른 글쇠라 혼동 없음. 파일이 선택돼 있을 때만 동작.
- **우클릭 메뉴**: 단일 항목(`FileTreeContextMenu`·`LibraryCellContextMenu`)과 다중 선택(`BatchSelectionMenu`) 양쪽에 **"빠른 이동…"**(아이콘 `bolt.folder` 또는 유사) 버튼 신설. 기존 "폴더로 이동…"(다중 선택에만 있던 것)은 **그대로 남긴다** — "목록에 없으면 지금처럼 창을 열 수 있다"(방향 문서 요구사항)는 이 기존 버튼이 그대로 맡는다. 단일 항목에는 "폴더로 이동…"이 원래 없었으므로 이번에 "빠른 이동…" 옆에 "다른 폴더로 이동…"(NSOpenPanel)도 같이 신설(패리티).

### 4.3 화면

- 새 뷰 `QuickMovePopover`(가칭) — `.popover` 또는 작은 패널로 목적지 목록(`quickMoveFolders`, 등록 순서)을 보여주고, 클릭하면 즉시 `appState.performBatchMove(urls:to:)` 호출 후 닫힌다. 하단에 "다른 폴더로 이동…"(NSOpenPanel) 버튼 상시 노출.
- 대상 파일 집합: 다중 선택 중이면 `fileSelection`, 아니면 우클릭/단축키 시점의 단일 파일.
- 이동 실패(권한 등)는 기존 `reportBatchFailures` 경로 그대로 재사용 — 새 오류 처리 불필요.

## 5. 파일 구조

**새로 만드는 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Models/QuickMoveFolder.swift` | `Identifiable·Equatable·Codable` 모델(id·url·addedAt) — `FavoriteItem`과 같은 모양, 별도 타입 |
| `Sources/Views/QuickMovePopover.swift` | 목적지 목록 화면(`quickMoveFolders` 표시 + 빈 상태 안내 + "다른 폴더로 이동…" 버튼) |
| `Tests/CmdMDTests/QuickMoveFolderStoreTests.swift` | 등록·제거·중복 등록 방지·존재하지 않는 경로 로드 시 필터링 |

**손대는 기존 파일** (전부 최소 변경)

| 파일 | 변경 |
|---|---|
| `Sources/Views/SidebarView.swift` | `FavoritesListView`에 "기본 위치" 섹션 추가, `FileTreeContextMenu`에 "빠른 이동 목록에 추가/제거" 토글 + "빠른 이동…"·"다른 폴더로 이동…" 버튼 추가 |
| `Sources/Views/BatchSelectionMenu.swift` | "빠른 이동…" 버튼 추가(기존 "폴더로 이동…"은 유지) |
| `Sources/Views/LibraryView.swift`(`LibraryCellContextMenu`) | 폴더 셀에 "빠른 이동 목록에 추가/제거" 토글 신설 + "빠른 이동…"·"다른 폴더로 이동…" 버튼 추가 |
| `Sources/Models/Shortcuts.swift` | `.quickMove` 케이스 + 기본 단축키 `⌥⌘M` |
| `Sources/App/AppState.swift` | `quickMoveFolders` 상태(로드·저장, `favorites` 관례 재사용) · `addToQuickMoveFolders`/`removeFromQuickMoveFolders` · `promptQuickMove(urls:)`(팝오버 상태 세팅) — 실제 이동은 기존 `performBatchMove` 재사용, 새 이동 로직 없음 |

## 6. 이번에 하지 않을 것

- 최근 이동한 폴더 자동 기억(등록 없이 학습) — 범위 밖, 필요해지면 별도 조각.
- C(두 폴더 나란히 보기)·E(폴더 전환 매끄럽게) — 각각 별도 조각.
- 기존 "폴더로 이동…"(NSOpenPanel) 제거 — 그대로 유지.

## 7. 검증 계획

- `QuickMoveFolderStoreTests`: 등록 시 목록에 추가·중복 등록 방지(같은 URL 재등록 무시)·제거·앱 재시작 시 존재하지 않는 경로 필터링(즐겨찾기 로드 관례와 동일).
- 기존 `swift test` 전체 그린 유지(현재 기준선 872개 이상 — 조각 A 이후 갱신치 재확인 후 계획 문서에 명시).
- 수동 스모크(자동 불가 영역): 사이드바에 기본 위치 4개 표시·클릭 시 폴더 전환, 폴더 우클릭 "빠른 이동 목록에 추가"로 등록 후 팝오버에 나타남, 단축키·우클릭 메뉴로 팝오버 뜨고 클릭 시 실제 이동+되돌리기 동작, 등록 안 한 상태에서 "다른 폴더로 이동…"으로 여전히 이동 가능.
