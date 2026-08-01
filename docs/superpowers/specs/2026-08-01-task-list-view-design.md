# 할일 목록 보기 — 설계

- 날짜: 2026-08-01
- 요청: 레고 "됐다. 이제 todolist보기 화면을 만들자"(문서에서 할일 찾기 → Todoist 실사용 확인 직후)
- 결정 방식: `ask` 도구 4문항(보려는 것·범위·완료 처리·진입점) 직접 확인 후 착수.

## 결정 사항(레고 확인 완료)

| 질문 | 결정 |
|---|---|
| 보려는 것 | 둘 다 — Todoist 실시간 할일 목록 + 이 앱이 보낸 기록(이력) |
| 범위 | 등록된 프로젝트 구분 없이 Todoist 전체 프로젝트 통틀어 |
| 완료 처리 | 양방향 — 앱에서 체크하면 Todoist에서도 실제로 완료 처리 |
| 진입점 | 새 화면(File 메뉴·커맨드팔레트 "할일 목록 보기") |

## 데이터 흐름

1. `AppState.openTaskListView()` — 시트를 열고 `refreshTodoistTasks()`(할일)·`loadTodoistProjects()`(행에 프로젝트 이름 표시용)·`loadSentTaskRecords()`(보낸 기록) 동시 실행.
2. **Todoist 탭**: `TodoistService.fetchTasks(token:)` — `GET /api/v1/tasks`(project_id 등 필터 없이 호출해 전체 프로젝트 통틀어), `{results:[...], next_cursor}` 페이지네이션 응답을 기존 `decodeList` 제네릭 헬퍼로 디코드. 체크 버튼 → `completeTodoistTask(_:)` → `TodoistService.closeTask(taskId:token:)`(`POST /api/v1/tasks/{id}/close`) → 성공 시에만 목록에서 제거(낙관적 갱신 없음, 실패하면 그대로 남아 재시도 가능).
3. **보낸 기록 탭**: `SentTaskLogStore`(신규 actor, 전례 `MoveLogStore`) — `sendSelectedTasksToTodoist()`가 매 전송 성공마다 `SentTaskRecord`(문서명·경로·시각·Todoist 쪽 id)를 append. 최근 200건만 유지.

## 발견·수정한 기존 결함(이번 확장 중)

`sendSelectedTasksToTodoist()`가 "성공 개수"만 세고 `selected.prefix(succeeded)`로 "보낸 것"을 추정하던 방식은, **앞쪽 항목이 실패하고 뒤쪽 항목이 성공하면 실패한 항목이 잘못 제거되고 성공한 항목이 목록에 남는** 결함이 있었다. 실제 성공한 `id` 집합을 직접 추적하도록 수정 + 회귀 테스트(`testSendSelectedTasksTracksActualSuccessNotJustCount`) 추가.

## API 계약 확정 근거

이전 두 차례(410 폐지·필드명 오류) 실패를 반복하지 않기 위해, 이번엔 착수 전에 Todoist 공식 문서에서 `Get Tasks`(`GET /api/v1/tasks`)·`Close Task`(`POST /api/v1/tasks/{task_id}/close`) 두 엔드포인트의 실제 응답 예시를 직접 읽고 확정한 뒤 구현했다.

## 이번에 하지 않은 것

- 하위작업(subtask)·라벨·마감일 편집 — 읽기+완료 처리만.
- 보낸 기록에서 Todoist 실시간 완료 상태 동기화 표시(이력은 "언제 뭘 보냈나"만, 그 뒤 상태 추적 없음).
- 페이지네이션(다음 커서) — 첫 페이지(기본 50개)만. 더 필요하면 후속.
