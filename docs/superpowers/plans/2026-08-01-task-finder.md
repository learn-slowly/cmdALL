# 문서에서 할일 찾아서 등록 — 구현 계획

- 날짜: 2026-08-01
- 설계 문서: `docs/superpowers/specs/2026-08-01-task-finder-design.md`
- 상태: **완료(2026-08-01)** — 코드+테스트까지, 재패키징·설치 확인은 별도(worklog 참고).

## 새로 만든 파일

| 파일 | 책임 |
|---|---|
| `Sources/Models/TaskCandidate.swift` | 할일 후보(체크박스/AI 구분) |
| `Sources/Services/TaskExtractor.swift` | 마크다운 체크박스 파싱(순수) |
| `Sources/Services/TaskPromptBuilder.swift` | AI 탐지 프롬프트(순수) |
| `Sources/Services/TaskOutputParser.swift` | AI 응답 JSON 배열 파싱(순수) |
| `Sources/Services/TaskFinderService.swift` | 체크박스+AI 오케스트레이션(actor) |
| `Sources/Services/TodoistService.swift` | Todoist REST API v2 클라이언트(actor, `TodoistTransport` 추상화) |
| `Sources/App/AppState+TaskFinder.swift` | 화면 배선(진입점·탐지·선택·전송·설정) |
| `Sources/Views/TaskFinderView.swift` | 시트 화면 |
| `Tests/CmdMDTests/TaskExtractorTests.swift` | 체크박스 파싱 7건 |
| `Tests/CmdMDTests/TaskOutputParserTests.swift` | JSON 파싱 8건 |
| `Tests/CmdMDTests/TaskFinderServiceTests.swift` | 오케스트레이션 5건 |
| `Tests/CmdMDTests/TodoistServiceTests.swift` | API 클라이언트 9건 |
| `Tests/CmdMDTests/AppTaskFinderStateTests.swift` | 화면 배선 10건 |

## 손댈 기존 파일(최소 배선)

- `Sources/App/AppState.swift` — 상태 변수·서비스 프로퍼티·init 대입.
- `Sources/Models/Settings.swift` — `todoistAPIToken`·`todoistDefaultProjectId`·`todoistDefaultProjectName`(하위호환 디코드).
- `Sources/Views/ContentView.swift` — 시트 연결.
- `Sources/Views/CommandPaletteView.swift`·`Sources/App/CmdMDApp.swift` — 진입점("문서에서 할일 찾기").
- `Sources/Views/SettingsView.swift` — "문서에서 할일 찾기 → Todoist" 섹션(GeneralSettingsView).

## 검증

- `swift test` **1,373개**(기존 1,334 + 신규 39) 전량 통과, 회귀 0.
- `swift build` 경고 없음(신규 코드 관련).
- `scripts/test_package_app.sh` 패키징 가드 통과.
- 수동 스모크(레고): 마크다운 문서에서 체크박스+AI 후보 확인 → Todoist 토큰 입력 → 연결 확인(프로젝트 목록) → 몇 개 골라 전송 → 실제 Todoist 앱에서 확인. **아직 미실시.**

## 후속(범위 밖, 필요하면 다음 조각)

- 폴더/볼트 전체 일괄 훑기.
- 파일 컨텍스트 메뉴(우클릭) 진입점.
- Todoist 외 다른 서비스(Things·미리알림) 지원.
- 토큰 Keychain 저장 전환(다른 미래 API 연동과 함께 한 번에 검토).
