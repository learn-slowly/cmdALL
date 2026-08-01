# 할일 목록 보기 — 구현 계획

- 날짜: 2026-08-01
- 설계 문서: `docs/superpowers/specs/2026-08-01-task-list-view-design.md`
- 상태: **완료(2026-08-01)** — 코드+테스트까지, 재패키징·설치 확인은 worklog 참고.

## 새로 만든 파일

| 파일 | 책임 |
|---|---|
| `Sources/Models/SentTaskRecord.swift` | 전송 이력 한 건 |
| `Sources/Models/TaskListTab.swift` | 화면 두 탭 구분 |
| `Sources/Services/SentTaskLogStore.swift` | 전송 이력 JSON 영속(최근 200건) |
| `Sources/App/AppState+TaskList.swift` | 화면 배선 |
| `Sources/Views/TaskListView.swift` | 시트 화면(세그먼트 탭 2개) |
| `Tests/CmdMDTests/SentTaskLogStoreTests.swift` | 저장소 5건 |
| `Tests/CmdMDTests/AppTaskListStateTests.swift` | 화면 배선 7건 |

## 손댈 기존 파일

- `Sources/Services/TodoistService.swift` — `TodoistTask`/`TodoistDue` 모델, `fetchTasks`·`closeTask` 추가, `decodeList` 제네릭화(프로젝트·할일 공용), `createTask`가 `Bool` 대신 생성된 `TodoistTask?`를 돌려주도록 변경(보낸 기록에 Todoist id 연결용).
- `Sources/App/AppState.swift` — 상태 변수·`sentTaskLogStore` 프로퍼티·init 대입.
- `Sources/App/AppState+TaskFinder.swift` — `sendSelectedTasksToTodoist()`가 성공한 항목마다 `SentTaskRecord`를 기록하도록 확장 + **기존 "성공 개수만 세던" 결함 수정**(설계 문서 §발견·수정한 기존 결함).
- `Sources/Views/ContentView.swift`·`CommandPaletteView.swift`·`CmdMDApp.swift` — 시트 연결 + 진입점("할일 목록 보기").
- `Tests/CmdMDTests/TodoistServiceTests.swift`·`AppTaskFinderStateTests.swift` — `createTask` 반환 타입 변경에 따른 기존 테스트 조정 + `fetchTasks`/`closeTask`/보낸 기록 신규 테스트 추가.

## 검증

- `swift test` **1,393개**(기존 1,374 + 신규 39, 그중 일부는 기존 파일 확장분) 전량 통과, 회귀 0.
- `swift build` 경고 없음(신규 코드 관련).
- `scripts/test_package_app.sh` 패키징 가드 통과.
- 수동 스모크(레고): Todoist 탭에서 실제 할일 목록 확인 → 체크 → Todoist 앱에서도 완료 확인 → 보낸 기록 탭에서 이전에 보낸 할일 확인. **아직 미실시.**
