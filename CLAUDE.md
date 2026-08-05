# cmdALL — Claude Code 개발 지시서

> 저장소 루트의 **규칙 문서**다. 앱을 만들 때 항상 이 규칙을 따른다.
> 여기엔 **거의 안 바뀌는 것만** 둔다 — 진행 상태·완료 날짜·테스트 개수는 `docs/worklog.md`,
> 다음에 할 일은 `docs/todolist.md`, 기획·요구사항은 `CmdMD-fork_prd.md`.
> 어느 문서를 어떤 순서로 보는지는 `AGENTS.md`(문서 지도) 참조.

## 프로젝트 개요

macOS 네이티브 리더 + 한글/오피스 문서 처리 + 내용 검색·RAG(자료에 묻기) 도구.
CmdMD(MIT, 구요한/CMDSPACE)를 포크해 만든다. 상세 사양은 PRD(`CmdMD-fork_prd.md`).

## 기술 스택

- 앱: Swift 5.9+ / SwiftUI, Swift Package(SPM), macOS 14+
- 문서 엔진: kordoc CLI (Node 18+) — `Process`로 호출하는 외부 도구
- AI: claude CLI (`claude -p`) — `Process`로 호출하는 외부 도구
- 검색: SQLite FTS5 (macOS 내장) — `trigram` 토크나이저(한국어 조사·복합어 부분일치), 3글자 미만 용어는 `LIKE` 폴백
- 보기: PDFKit(PDF), ImageIO/AppKit(이미지)

## 핵심 규칙 (반드시 지킨다)

- **비샌드박스 유지.** 샌드박스로 바꾸면 kordoc·claude 서브프로세스 호출이 막힌다.
- **kordoc·claude는 직접 구현하지 않는다.** Node/CLI를 `Process`로 부르고 결과(stdout/JSON)를 받는다. 경로 탐지 실패 시 사용자에게 안내만 하고 크래시하지 않는다.
- **파일 변경은 제안→확인→실행.** 라우팅·폴더 정리·양식 채우기 등 파일을 옮기거나 바꾸는 동작은 사용자 승인 없이 자동 실행하지 않는다. 이동·이름변경만 하고 삭제는 하지 않는다. 실행분은 로그로 남겨 undo를 지원한다.
- **추정을 사실로 적지 않는다.** 코드로 검증한 뒤 구현 방식을 확정한다. 불확실하면 "확인 필요"로 표시한다.
- **라이선스.** CmdMD·kordoc은 MIT라 사용 가능. Docufinder는 BSL 1.1이므로 **코드를 가져오지 않는다** — 아이디어/아키텍처만 독립 구현한다. LICENSE와 원작자 고지를 유지한다.
- **문서는 마크다운으로.** 새 산출 문서는 md로 만든다. PDF/HWPX 변환은 최종본 단계에서만.
- 신규 기능은 가능한 별도 파일·모듈로 분리해 업스트림(CmdMD) 변경 머지를 쉽게 둔다.

## 언어

- 코드 주석·커밋 메시지는 한국어로 쓴다.
- 글에서 '박다/박는다/박았다' 표현은 쓰지 않는다.

## 작업 방식

- **게이트** — 작업 전후로 `swift test` 전량 통과를 확인한 뒤 다음으로 넘어간다. 기준선 개수는 여기 적지 않는다(매번 늘어난다) — **`docs/worklog.md` 마지막 항목**이 최신 값이다. 패키징을 건드렸으면 `scripts/test_package_app.sh` 가드도 함께. `swift test`엔 정식 Xcode가 필요하다(CLT는 build만).
- **설계 → 계획 → 구현** 순서. 설계는 `docs/superpowers/specs/`, 구현 계획은 `docs/superpowers/plans/`에 남긴다.
- **작업 브랜치는 `main`** — 직접 커밋·푸시한다. 원격 `upstream`은 원작자(CmdMD) 저장소.
- **릴리스는 사용자 승인 후에만.** main 푸시 + 태그 push → `release.yml` CI → dmg·zip·SHA256SUMS 발행.
- **문서 역할 분담** — 규칙은 이 파일, 요구사항은 `CmdMD-fork_prd.md`, 다음에 할 것은 `docs/todolist.md`, 끝난 일은 `docs/worklog.md`(append-only). 작업 기록은 이 파일이 아니라 worklog에 남기고, 끝낸 항목은 todolist에서 **지운다**(완료 표시를 쌓지 않는다). 문서를 새로 만들거나 옮길 때는 전역 `~/.claude/CLAUDE.md`의 「프로젝트 문서 구조」를 따른다.

## 결정 사항 (다시 꺼내지 말 것)

- **정식 유료 인증서(연 14만원) 안 산다** — 레고 결정(2026-07-31). 다른 사람 컴퓨터의 macOS 차단 경고는 README의 터미널 설치 스크립트(`install_latest.sh`, 격리 표시가 안 붙음) 안내로 계속 우회한다. **먼저 제안하지 말 것** — 레고가 다시 원하면 그때만.
- **세 갈래를 다 키운다** — 레고 결정(2026-07-30): ① 파일 관리자(파인더 대체) 기능 ② GitHub 공개 배포 ③ 위키를 앱 안 정식 기능으로.

@AGENTS.md
