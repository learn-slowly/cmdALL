# 문서에서 할일 찾아서 등록 — 설계

- 날짜: 2026-08-01
- 요청: 레고 "문서에서 할일 찾아서 등록하는거 만들고싶어"
- 결정 방식: `ask` 도구로 직접 질문 6개(범위·탐지 방식·목적지·확인 흐름·프로젝트·토큰) 확인 후 착수. 별도 ralplan/deep-interview 미사용(S2와 같은 경량 진행).

## 결정 사항(레고 확인 완료)

| 질문 | 결정 |
|---|---|
| 대상 범위 | 지금 열어본 문서 1개(우선), 폴더 전체 훑기는 후속 |
| 탐지 방식 | 둘 다 — 마크다운 체크박스(`- [ ] ...`) 파싱 + AI가 본문을 읽고 찾은 후보 |
| 목적지 | Todoist(외부 서비스) — 이 앱이 처음 다루는 실제 인터넷 API 연동 |
| 확인 흐름 | 찾은 것을 먼저 목록으로 보여주고, 고른 것만 전송(기존 "제안→확인→실행" 원칙과 동일) |
| Todoist 프로젝트 | 기본 받은함(Inbox)·다른 프로젝트 둘 다 가능하게(설정에서 프로젝트 목록 불러와 선택) |
| 토큰 확보 | 레고가 즉시 발급해 넣을 수 있음(설정 화면에 입력 필드) |

## 이번에 하지 않은 것

1. 폴더/볼트 전체 일괄 훑기(문서 하나씩만).
2. 자동 실행(항상 버튼을 눌러야 함 — File 메뉴·커맨드팔레트).
3. Todoist ↔ 문서 양방향 동기화(전송 후 서로 무관, 체크박스 완료 처리 자동 반영 없음).
4. Todoist 외 다른 할일 앱(Things·미리알림 등) 연동.
5. 앱에서 새 Todoist 프로젝트 자동 생성(이미 있는 프로젝트 중 선택만).
6. 파일 컨텍스트 메뉴(우클릭) 진입점 — File 메뉴·커맨드팔레트만.

## 안전 관련(레고에게 통지)

Todoist API 토큰은 `AppSettings.todoistAPIToken`에 **평문 저장**된다(다른 설정값과 같은 `settings.json`). macOS Keychain 연동은 없다 — 개인 컴퓨터에서만 쓰는 개인용 앱이라는 전제로 감수한 트레이드오프. 이 컴퓨터에 접근 가능한 사람/프로그램이면 이론상 값을 읽을 수 있다.

## 데이터 흐름

1. `AppState.openTaskFinder()` — 활성 탭 파일이 있고 요약 가능한 종류(`AppState.isSummarizable`)면 시트를 열고 `runTaskFinder(at:)` 실행.
2. `runTaskFinder` — `ContentExtractor.body(for:)`로 본문 추출(office는 kordoc, pdf는 텍스트 추출 등 기존 경로 재사용) → `TaskFinderService.findTasks(body:isMarkdown:)`.
3. `TaskFinderService`(actor) — `TaskExtractor.checkboxTasks(from:)`(마크다운일 때만, 순수) + 본문이 있으면 `claude.ask(...)`로 `TaskPromptBuilder.detectPrompt`를 보내 `TaskOutputParser.parseAIResponse`로 JSON 배열 파싱. AI 실패해도 체크박스 결과는 살아남는다(부분 성공 원칙).
4. 화면(`TaskFinderView`) — 후보 목록(체크박스 유래는 기본 선택 ON, AI 유래는 기본 OFF), 체크한 것만 "Todoist로 보내기".
5. `AppState.sendSelectedTasksToTodoist()` — 선택분을 순서대로 `TodoistService.createTask(...)` 호출, 부분 실패 시 "N개 중 k개 보냈습니다" + 실패분은 목록에 남아 재시도 가능.
6. `TodoistService`(actor) — Todoist REST API v2(`https://api.todoist.com/rest/v2/`) HTTPS 직접 호출. `TodoistTransport` 프로토콜로 전송 계층 추상화(테스트가 가짜 응답 주입).
7. 설정 화면 "문서에서 할일 찾기 → Todoist" 섹션 — 토큰 입력·"연결 확인"(프로젝트 목록 불러오기 겸 토큰 검증)·기본 프로젝트 선택.

## 재사용(신규 로직 최소화)

- `ContentExtractor.body(for:kordoc:)` — 종류 무관 본문 추출(기존 `summarizeFile`·RAG·검색 인덱스와 동일 경로).
- `AppState.isSummarizable(url:)` — "이 문서에서 읽을 수 있나" 판정(기존 Claude 요약 진입 조건과 동일).
- JSON 배열 추출 패턴 — `CleanupPlanner.extractJSONObject`(객체판)의 배열판(`TaskOutputParser.extractJSONArray`).
- 부분 성공 집계 문구("N개 중 k개") — `StudyService`의 "청크 C개 중 k개 성공" 관례.
- URLSession 직접 호출 — `UpdateInstaller.swift`(GitHub 릴리스 다운로드)의 기존 전례, 다만 Todoist는 이 앱 최초의 "사용자 로그인 정보가 필요한" 외부 API.
