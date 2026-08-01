# cmdALL 다음에 할 것 (todolist)

> 코딩 세션에서 "다음에 뭘 집을까"를 보는 파일. 규칙은 `CLAUDE.md`, 기획·요구사항은 `CmdMD-fork_prd.md`, 끝난 일 기록은 `docs/worklog.md`.

**운영 규칙**

- 끝난 항목은 **여기서 지우고** `docs/worklog.md`에 기록한다. 완료 표시를 쌓지 않는다(쌓으면 두 번째 worklog가 된다).
- 항목은 **왜 / 어디 / 방향** 을 갖춘다. 맥락 없이 열어도 바로 착수할 수 있게.
- **나중** 칸은 착수 전 레고 확인이 필요하다. 임의로 시작하지 않는다.

---

## 지금 — 레고 실기 확인 대기

구현·배포는 끝났는데 실제로 눌러본 적이 없는 것들. 코드 작업이 아니라 **레고가 앱을 켜서 확인할 일**이다.

### 1. 두 폴더 나란히 보기 (조각 C)

- **왜**: 2026-07-29 구현·배포됐지만 수동 스모크가 안 끝났다. 화면을 두 칸으로 나누는 큰 기능이라 실기에서 처음 드러나는 문제가 있을 수 있다.
- **볼 것**: 두 폴더를 켜서 나란히 훑어보기 · 칸 사이 드래그로 파일 이동 · 칸 안 읽기 전용 미리보기 · "이 창에서 제대로 열기" 버튼으로 기존 탭에 열리는지.
- **어디**: `BrowsePane`·`DualPaneView`/`PaneView`·`PaneReaderView`·`DualPaneToggleButton`. 설계 `docs/superpowers/specs/2026-07-29-dual-pane-design.md`.

### 2. 사진 속 글자 검색 (이미지 OCR)

- **왜**: 2026-07-29 v0.9.418로 배포됐지만 실제 사진 파일로 검색해본 적이 없다. 기본값이 OFF라 켜야 동작한다.
- **볼 것**: 설정 > "사진 속 글자도 읽기 (OCR)" 켜기 → 글자 있는 사진이 든 폴더 색인 → 그 글자로 검색해서 사진이 잡히는지.
- **어디**: `AppSettings.ocrImagesEnabled` · `ContentExtractor` 이미지 분기 · `OCRService.loadCGImage(from:)`.

### 2.5. 선택 후 우클릭으로 Claude 호출

- **왜**: 2026-08-01 레고 요청 — 마우스로 글자를 드래그해 선택한 다음 오른쪽 버튼을 눌러도 AI를 부를 수 있으면 좋겠다는 요청 반영. 자동 테스트로는 실제 마우스 우클릭·메뉴 표시 자체를 재현할 수 없는 종류라(헤드리스 검증만 가능) 실기 확인이 필요하다.
- **볼 것**: 마크다운 편집 화면·마크다운 미리보기 화면(일반 노트 열기)·PDF 화면·한글/오피스 문서 화면(보기·편집 둘 다) 각각에서 글자를 드래그로 선택 → 오른쪽 버튼 → 메뉴 맨 위에 "Claude에게 물어보기"가 뜨는지 → 누르면 오른쪽 AI 패널이 열리고 선택한 글자가 컨텍스트로 잡히는지(패널에서 질문을 입력해 실제로 그 내용 기준으로 답이 오는지까지 1회). 선택 없이 우클릭했을 때는 항목이 안 뜨는지도 같이 확인.
- **어디**: `Sources/Views/EditorTextView.swift`(`CmdMDTextView.menu(for:)`) · `Sources/Views/PDFReaderView.swift`(`CmdMDPDFView.menu(for:)`) · `Sources/Views/PreviewView.swift`(`DropThroughWebView.menu(for:)`) · 배선은 `MainEditorView.swift`·`OfficeReaderView.swift`.

### 3. 학습도우미 S1 완료 — 전용 화면에서 카드/문제 만들고 저장해보기

- **왜**: S0(프리셋 버튼) 실기 확인 완료(2026-08-01, 레고 "쓸만한거 같아" 판정)로 게이트 통과 후 진행한 S1(코어+카드+퀴즈+저장) 구현이 오늘 전부 끝났다. 왼쪽 리본에 학습도우미 전용 화면이 생겼고, 교재 파일을 골라 실제로 Claude가 정리 카드·연습 문제를 만들어 새 마크다운 노트로 저장하는 것까지 전 구간이 동작한다.
- **볼 것**: 왼쪽 리본 학습도우미(졸업모자) 아이콘 클릭 → 교재 파일 선택(PDF·한글/워드·이미지·마크다운 아무거나) → "정리 카드" 또는 "연습 문제" 고르고 개수 정하기 → 화면에 "보낼 분량 약 N자 · 조각 C개"가 뜨는지 → 만들기 → 잠시 기다린 후 카드/문제 미리보기가 뜨는지(제목·내용·근거 발췌) → "노트로 저장" 눌러서 실제 파일이 생기는지 → "노트 열기"로 그 파일 내용이 제대로 보이는지(카드/문제 형식·근거 위치 표시). 로그인 안 된 상태·글자 없는 사진 등 실패 상황에서 한국어 안내가 뜨는지도 겸사겸사.
- **의도적으로 뺀 것(이번 화면엔 없음)**: 교재의 일부만 골라 보내는 기능(지금은 항상 파일 전체) — 필요하면 다음에 추가.
- **어디**: 설계 `docs/superpowers/specs/2026-07-31-study-helper-design.md`·계획 `docs/superpowers/plans/2026-07-31-study-helper.md`. 화면 `Sources/Views/StudyHelperView.swift`·배선 `Sources/App/AppState+Study.swift`. S1 로직 산출물: `Sources/Models/StudyLocator.swift`·`StudyItem.swift`·`StudyScope.swift`·`StudyChatDraft.swift`·`Sources/Services/StudySourceLoader.swift`·`StudyChunker.swift`·`StudyPromptBuilder.swift`·`StudyOutputParser.swift`·`StudyService.swift`·`StudyNoteWriter.swift`.
- **다음**: 이 실기 확인이 끝나면(레고 판정) S3(대화, 레고 확정 우선순위) 또는 S1 피드백 반영으로 이어간다.

---

## 나중 (착수 전 레고 확인 — 임의로 시작하지 말 것)

- **조각 E — 폴더 오갈 때 화면 전환 매끄럽게**: "먼저 다시 살펴보고 필요할 때만" 하기로 한 항목. 지금도 쓸 만하면 안 해도 된다.
- **뜻으로 찾기(의미 검색)**: codex 자문에서 나온 제안 6개 중 맨 마지막으로 미룬 것. 임베딩이 들어가면 지금의 "임베딩 없는 B안" 구조를 바꿔야 하므로 착수 전 반드시 상의.
- **HWPML(아주 옛날 한글 파일 형식) 원본 그대로 보기**: MS 오피스·HWP·HWPX는 전부 이미 됨(2026-07-30 레고 확인 완료). 남은 건 HWPML 하나뿐인데 요즘 거의 안 쓰이는 형식이라 변환 도구가 아예 못 읽는다 — 되게 하려면 훨씬 무거운 도구가 필요해 보류. 실사용에서 이 형식 파일이 실제로 나오면 그때 재검토.
