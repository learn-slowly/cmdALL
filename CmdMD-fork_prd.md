# cmd-docu PRD (v2)

> CmdMD(MIT, 구요한/CMDSPACE)를 포크해 만든다. 리더(마크다운·PDF·이미지·HWP·오피스) + Claude 연동 + 한글문서 읽기·쓰기(kordoc) + 내용 검색(Docufinder 아이디어) + 파일 정리. 이 문서는 Claude Code에 그대로 넘기는 개발 지시서다. v1 대비 kordoc·내용검색을 추가하고 단계를 우선순위 3티어로 재정리했다.
> **병합 기록(2026-07-25)**: `cmd-docu_개선작업_문서.md`(속도 개선·미디어 플레이어+짝꿍 노트·PDF 폭 버그 등 실사용 기록)의 내용을 이 문서에 합쳤다 — §3.13(미디어)·§3.1 PDF 버그 수정·Phase 8.6 신설. 원본 문서는 상세 진단 과정(왜·어떻게 찾았는지) 기록용으로 그대로 둔다.

## 1. 개요

| 항목 | 내용 |
| --- | --- |
| 프로젝트명 | cmd-docu (CmdMD의 "cmd" + Docufinder의 "docu") |
| 한 줄 설명 | 마크다운·PDF·이미지·HWP·오피스를 한 곳에서 읽고, Claude에게 묻고, 내용으로 검색하고, 알맞은 자리로 정리하는 macOS 네이티브 도구 |
| 목적 | 종류 가리지 않고 한 앱에서 읽기 → 본문 검색 → Claude 질의 → 정리/생성까지. 관공서 HWP·정부지원사업 서류·논문 PDF가 핵심 대상 |
| 타겟 사용자 | 레고 1인 (개인용). 배포는 비목표 |
| 기술 스택 | Swift/SwiftUI (앱) · Node 18+ (kordoc CLI) · SQLite FTS5 (검색 인덱스) · macOS 14+ |
| 배포 환경 | 로컬 빌드(`swift build -c release`) → `.app`, 본인 머신 설치 |
| 상태 | 구현 진행 — Phase 0~10 완료(2026-07-02, Phase 8.6 미디어 플레이어+짝꿍 노트 포함), **Phase 11 자동 업데이트 완료(2026-07-25)**, PDF 리더 본문 폭 버그 수정(2026-07-25), **Phase 12 빠른 파인더(못 여는 파일 미리보기) 구현 완료·실기 확인 대기(2026-07-25)** |

원본 리포: https://github.com/johnfkoo951/CmdMD (MIT, 최신 v1.4.6) 엔진: kordoc https://github.com/chrisryugj/kordoc (MIT) 아이디어 참고: Docufinder https://github.com/chrisryugj/Docufinder (BSL 1.1 — 코드 차용 금지, 아이디어만)

## 2. 배경 및 문제 정의

CmdMD는 "리뷰 우선" 마크다운 리더이자 Obsidian 볼트 라우터다. 강점은 분명하지만 마크다운만 본다.

레고의 실제 작업은 마크다운에 그치지 않는다. 관공서 HWP, 정부지원사업 서류, 논문·보고서 PDF를 읽고 검색하고 텍스트를 뽑는 일이 잦고, 스크린샷·도판 이미지도 자주 본다. 또한 읽은 다음이 문제다 — 어디 뒀는지 모르는 문서를 파일명이 아니라 내용으로 찾고 싶고, 읽던 문서를 두고 곧바로 Claude에게 묻고 싶고, 노트는 알맞은 PARA 폴더로 가야 하고, 성명·공보는 다시 공문서 양식으로 나가야 한다.

이 포크는 여섯 줄기로 그 간극을 메운다. (1) PDF·이미지를 같은 창에서 본다. (2) HWP·오피스를 kordoc으로 읽어 마크다운으로 렌더한다. (3) 같은 kordoc으로 마크다운을 다시 HWPX 공문서로 쓴다. (4) 읽던 문서를 Claude 구독으로 질의한다. (5) 노트를 Claude가 알맞은 PARA 폴더로 보낸다. (6) 여러 문서를 내용으로 가로질러 검색한다. (4)·(5)·(6)의 파일 변경은 "Claude가 제안 → 레고가 확인 → 실행" 순서를 지킨다.

## 3. 핵심 기능

### 3.1 PDF 리더 (PDFKit) — 보기

- `.pdf`를 PDFKit 뷰어로 연다. 페이지 이동·문서 내 검색·텍스트 선택/복사·줌/맞춤·회전.
- PDF의 "보기"는 PDFKit, "내용 추출(검색·AI·마크다운화)"은 3.3 kordoc이 맡는다(역할 분리).
- **버그 수정(2026-07-25)**: 원래 있던 페이지 썸네일 칸(왼쪽)을 열 때마다 통째로 새로 만드는 구조라, 두 번째로 여는 PDF부터 폭 지정이 안 걸려 본문이 오른쪽 끝 ~55pt로 눌리는 결함이 있었다(실측: 첫 PDF 160/611, 이후 713/58). 게다가 그 썸네일 칸은 애초에 한 번도 제대로 그려진 적이 없었다(프레임 0×0). 사용자 결정으로 **썸네일 칸 자체를 없애고** 본문이 항상 화면 전체 폭을 쓰게 했다(실측 760pt).
- 우선순위: 필수 / 티어 1

### 3.2 이미지 리더 — 보기

- `.png .jpg .jpeg .heic .webp .gif` 단독 이미지를 같은 창에서. 화면맞춤 + 줌/팬.
- 구현은 WebView 재사용 또는 네이티브 `NSImage` 중 택1(Phase 0 확인 후).
- 우선순위: 필수 / 티어 1 (가장 작은 변경 → 코드 파악용)

### 3.3 한글·오피스 읽기 (kordoc) — 보기/추출

- **설명**: HWP3·HWP5·HWPX·HWPML·PDF·XLS·XLSX·DOCX를 kordoc으로 마크다운 변환 → 기존 마크다운 렌더 파이프라인에 태워 보여준다. LibreOffice 같은 무거운 의존성 불필요.
- **사용자 시나리오**: HWP 파일을 열면 kordoc이 마크다운으로 변환하고, 탭에 렌더된 본문이 뜬다. 표·각주·이미지도 함께.
- **연동 방식**: 앱이 `Process`로 `npx kordoc <파일> --format json` 호출 → markdown + blocks 수신. (대안: kordoc MCP 경유)
- **데이터**: 입력 = 로컬 문서 경로. 출력 = markdown + IRBlock 구조 + 메타데이터.
- 우선순위: 필수 / 티어 1 (레고 핵심 대상이 HWP·서류라 가치 큼)

### 3.4 한글·오피스 쓰기 (kordoc) — 패치/양식

- **설명**: 마크다운을 다시 한글문서로. 두 가지 — (a) `kordoc patch`로 원본 서식 1바이트도 안 건드리고 바뀐 텍스트만 무손실 교체, (b) `kordoc fill`로 양식 빈칸 자동 채우기(서식 보존). (kordoc 실제 API 검증(Phase 5a)으로 generate 부재 확인 — 신규 생성은 앱이 md로 작성 후 필요 시 patch/fill로 반영)
- **사용자 시나리오**: 받은 양식(신청서)에 값을 채워 되돌려줌. 또는 기존 HWP/HWPX 원본의 텍스트만 바꿔 서식을 보존한 채 저장.
- **제약**: HWP5 바이너리는 패치(텍스트 교체)만. 새 문서 생성 기능은 없음 — 신규 문서는 마크다운으로 작성.
- 우선순위: 필수 / 티어 2

### 3.5 Claude 구독 연동 (claude -p)

- **설명**: 열린 문서(또는 선택 영역)를 프롬프트와 함께 Claude에 보내고 답을 사이드 패널에 표시. 답은 노트에 마크다운으로 삽입/저장.
- **연동 방식**: `Process`로 로컬 `claude` CLI를 `claude -p`로 호출, stdout 수신. 인증은 구독 로그인(claude.ai 아님), 사용량은 월간 Agent SDK 크레딧 차감.
- **참고**: `claude -p`(Claude Code)는 레고의 kordoc MCP를 이미 쓸 수 있어, "이 HWP 뭐라 적혔어?"를 Claude가 알아서 kordoc으로 파싱하게도 된다.
- 우선순위: 필수 / 티어 2

### 3.6 Claude 스마트 라우팅 (노트 PARA 자동 분류)

- 보낼 때 규칙 미매칭이면 Claude가 본문을 읽고 PARA 목적지를 제안 → 레고 확인 → 기존 "볼트로 보내기" 이동.
- PARA 목적지(레고): `10000_Projects/{Living_with_Damage, Build_and_Deploy, Left_Forward}`, `20000_Areas`, `30000_Resources`, `40000_Archive`.
- 안전장치: 제안만, 확인 없는 자동 이동은 기본 OFF.
- 우선순위: 필수 / 티어 2

### 3.7 내용 검색 (Docufinder 아이디어)

- **설명**: 파일명이 아니라 본문으로 찾는다. 폴더를 등록하면 kordoc으로 본문을 마크다운으로 뽑아 SQLite FTS5에 인덱싱 → 키워드 검색. Everything 스타일 파일명 검색 병행. 파일 추가/수정 시 자동 재인덱싱(파일 감시).
- **사용자 시나리오**: 검색창에 키워드 → HWP·PDF·오피스 본문에서 결과를 1초 안에. 결과 클릭으로 미리보기, 더블클릭으로 열기.
- **참고**: Docufinder 발상을 따르되 코드는 차용하지 않는다(BSL). 엔진은 kordoc(MIT). 이 기능은 LLM-Wiki 패턴의 "원본 소스 검색" 층과 동일하다(§8).
- **구현 확정(2026-07-01)**: Phase 7로 완료 — kordoc/PDFKit 추출 + SQLite FTS5 영속 인덱스 + FSEvents 파일감시. 이후 Phase 9 후속으로 토크나이저를 `unicode61`→**`trigram`(부분일치)** 으로 전환해 한국어 조사·복합어를 해결("평가서"→"평가서에", "선거"→"지방선거"), 3글자 미만 용어는 같은 테이블 `LIKE`(body+filename) 폴백. 구 인덱스는 자동 감지해 재생성 후 등록 폴더를 재인덱싱. 감수: 영어도 단어 일치→부분일치로 바뀜(의도·승인).
- 우선순위: 선택 / 티어 3 (지금까지 중 가장 무거운 추가 — 인덱서·파일감시)

### 3.8 Claude 폴더 정리 (배치)

- 어수선한 폴더를 Claude가 종류·주제별 정리 계획으로 제안 → 레고가 승인한 만큼만 이동/이름변경. 삭제 없음, 이동 로그로 undo.
- **중복 인지**: Desktop Commander와 기능이 겹침. 그래도 리더 안에서 처리하려는 선택.
- 우선순위: 선택 / 티어 3

### 3.9 PARA 라이브러리 뷰 (리더 ⇄ 라이브러리)

- **설명**: 파일 하나를 여는 "리더" 위에, 폴더를 펼쳐 그 안의 파일을 격자/리스트로 훑는 "라이브러리" 모드를 더한다. PARA를 보내기(라우팅)뿐 아니라 탐색 축으로도 쓴다 — 첨부(사진·PDF·영상·오피스)를 텍스트의 곁다리가 아니라 그 자체로 본다.
- **모드 토글**: `mainMode`(reader/library)를 툴바 세그먼트로 전환. 하위 보조토글은 모드 따라 교체(리더=Source·Split·Preview, 라이브러리=List·Grid).
- **동선(절충)**: 파일 클릭→리더, 폴더 클릭→라이브러리 자동전환하되 토글이 우선(덮어쓰기). 관통축은 "현재 폴더".
- **PARA 렌즈**: 사이드바 트리를 `legoSeed` 기준 그룹·정렬, 경로로 분류 판별(Archive는 차분하게 dim, Projects는 또렷하게).
- **썸네일**: QuickLook(`QLThumbnailGenerator`)으로 전 종류, lazy 생성+캐시.
- **경계**: 읽기/탐색 전용 — 파일 이동·삭제는 하지 않는다(정리는 3.8). **Phase 8의 폴더 선택·미리보기 기반을 재사용·확장한다.**
- 우선순위: 선택 / 티어 3 (Phase 8 다음, 9 앞)

### 3.10 미리보기 속도 다듬기 (성능)

- **설명**: 기능을 쌓는 동안 미뤄둔 프리뷰 병목을 제거한다(코드 검증 2026-06-30 반영). (a) 코드 색칠(highlight.js)을 CDN→앱 번들 로컬 로드로, (b) 파일 트리 스캔을 메인 스레드→백그라운드로. 라이선스 고지(highlight.js 누락) 정정 동반.
- **배경**: 미리보기는 `WKWebView` 기반이고 코드/수식/다이어그램 자산을 매 렌더 `cdn.jsdelivr.net`에서 받는다 → 오프라인 취약. **highlight.js는 이미 Highlightr 패키지가 로컬 번들(1MB)로 동봉**(`package_app.sh`가 `Contents/Resources`로 복사)하는데 미리보기만 별도 CDN을 또 써서 중복 → 기존 번들 인라인 주입으로 거의 공짜 로컬화. 파일 트리(`buildFileTree`)는 메인 스레드 동기 재귀(depth 10, 펼친 폴더만)라 큰 볼트에서 멈춘다.
- **검증으로 정정된 것**: 미리보기 렌더는 **이미 250ms 디바운스**가 있다(`PreviewView.swift`). "타이핑마다 통째 리로드"는 사실이 아니며(멈춘 뒤 1회·스크롤 보존), **DOM 부분갱신(A-3)은 실익 작고 리스크(JS 재초기화·체크박스 리스너·레이스) 커 보류**. **KaTeX/Mermaid 로컬화는 별도 자산 동봉 필요해 후속**(KaTeX 기본 비활성).
- **경계**: 동작·기능은 그대로 두고 로드 출처/실행 위치만 바꾸는 성능 작업. 9(RAG) 앞으로 당겨 바닥을 다진다.
- 우선순위: 필수 / 티어 3 (Phase 8.5 다음, 9 앞)

### 3.11 자료에 묻기 — 가벼운 RAG (구현 확정: B안, 임베딩 없음)

- **설명**: 원안(임베딩·벡터·하이브리드)을 브레인스토밍으로 **B안(임베딩 없이 FTS5 근거 + Claude 답변)** 으로 재정의해 구현(2026-07-01). 근거 회수 = 원질문 AND 검색 + 원질문 토큰·확장어 OR 재검색(질의 확장 토글은 Claude 확장어 생성만 제어, 기본 ON — OR 재검색 자체는 항상 수행). Claude(`claude -p`)가 **근거만으로** 한국어 답변. 답변의 출처 `[n]` 클릭 → 해당 문서 위치로 점프(마크다운=줄 / PDF=페이지 / 한글·오피스=파일 열기까지).
- **사용자 시나리오**: 커맨드 팔레트 "자료에 묻기 (RAG)" → 시트에서 질문 → 답변 + 번호 출처 목록 → 출처 클릭으로 원문 위치 확인.
- **안전장치**: 근거 0건이면 **답변용 Claude 호출을 생략**(무근거 생성 차단·크레딧 절약; 질의 확장 ON이면 확장어 생성용 호출 1회는 검색 전에 선행됨). 근거 컨텍스트는 12k자 예산으로 절단. 원본 파일 불변(읽기 전용).
- **구성**: 전부 별도 파일 — 순수 헬퍼(`RagQueryExpansion`·`RagContextBuilder`·`RagPromptBuilder`·모델 `RagSource`) + I/O 헬퍼(`RagRetriever`=인덱스 질의, `RagPassageExtractor`=PDF/kordoc 접근·text 경로는 순수) + `RagService`(actor) + `AskCorpusView`(시트). 기존 `ClaudeService`·`ContentExtractor`·`SearchIndex` 재사용, **새 패키지 의존성 0**.
- **후속(A안·선택, 2026-07-01 조사 메모 — 코드 외 실측)**: 임베딩 업그레이드 — `NLEmbedding`은 한국어 미지원이라 `NLContextualEmbedding` CJK(무설치·512차원) 또는 Ollama `bge-m3`(고품질·설치 부담) 후보. **sqlite-vec는 macOS 시스템 SQLite에서 로드 불가** → 임베딩 BLOB 저장 + Swift 브루트포스 코사인(vDSP)이 현실적.
- 우선순위: 완료 / 티어 3 (Phase 9)

### 3.12 앱 내 자동 업데이트 (버튼 하나로 설치)

- **설명**: 기존 "Check for Updates"는 알림 + 브라우저 열기까지였다. 이제 앱이 직접 릴리스 zip을 **받고 → 검증하고 → 자기 자신을 교체하고 → 재시작 여부를 묻는다.** 진입점은 상태 표시줄의 업데이트 알약과 About 창 버튼(둘 다 같은 경로).
- **설계를 뒤집은 실측(2026-07-25)**: ad-hoc 서명·비샌드박스·`LSFileQuarantineEnabled` 미설정 앱 번들이 `URLSession`으로 받은 파일에는 **quarantine이 붙지 않는다**(실제 앱 번들 프로브로 확인 — `com.apple.provenance`만). 즉 **Apple 공증(연 $99) 없이도 Gatekeeper 차단 없이 자동 설치가 성립한다.** 그전 메모의 "직접 구현하려면 quarantine 자동해제 편법 필요"는 사실이 아니며 이 문서로 정정한다.
- **안전장치**: ① 릴리스의 `SHA256SUMS.txt`와 대조(불일치 시 중단) ② 교체 전 `codesign` 검증 + 번들 버전 대조 ③ **원자적 교체** — 기존 앱을 백업으로 옮기고 새 앱을 제자리에, 실패하면 즉시 원복(앱이 사라지지 않음) ④ 옛 번들은 삭제하지 않고 **휴지통**(삭제 금지 원칙) ⑤ 설치 위치에 쓰기 권한이 없으면 다운로드 전에 중단하고 터미널 설치를 안내.
- **재시작**: 종료가 실제로 진행될 때만(`applicationWillTerminate`) 새 인스턴스를 띄운다 — 저장 확인에서 취소해도 인스턴스가 둘이 되지 않는다. 옛 프로세스가 사라진 뒤 여는 껍데기 프로세스에 위임해 세션 파일 경합도 막는다. **떠 있는 시트(About 창)가 `NSApp.terminate`를 막으므로 먼저 닫고 종료**(실측·변이 시험으로 확정).
- **구성**: 전부 별도 파일 — 순수(`UpdateProgress`·`UpdateInstallError`·`UpdateAssets`) + 파일시스템(`BundleReplacer`) + actor(`UpdateInstaller`, 네트워크·서명 검증은 프로토콜 주입). **새 패키지 의존성 0**(CryptoKit·Foundation·AppKit은 시스템).
- **배포 경로 두 갈래**: 앱 내 업데이트(격리 없음) / 브라우저 다운로드(격리 붙음 → `xattr` 해제 또는 `scripts/install_latest.sh` curl 설치). 후자를 위해 패키징에서 번들 리소스에 쓰기 권한을 준다 — 0444로 배포되면 `xattr -dr`이 Permission denied로 실패해 **앱 본체 격리가 남는다**(실측).
- 우선순위: 완료 / 티어 3 (Phase 11)

### 3.13 미디어 플레이어 + 짝꿍 노트 (음악·동영상)

- **설명**: 음악(mp3·m4a·aac·wav·aiff·flac)·동영상(mp4·mov·m4v)을 열면 플레이어와 "짝꿍 마크다운 노트"가 한 화면에 뜬다. 목표는 재생이 아니라 **재생하지 않고도 그 파일이 뭔지 아는 것** — cmd-docu의 뿌리가 마크다운 노트 도구이므로 "이 mp3에 대한 메모"도 결국 마크다운 문서 하나로 다룬다.
- **짝꿍 노트 규칙**: 미디어 파일 옆에 같은 이름 + `.md`를 더한 노트를 둔다(예: `삐약이_데모.mp3` ↔ `삐약이_데모.mp3.md`). DB가 아니라 파일 옆 평문 노트라서 Dropbox 동기화·볼트 이동에 그대로 따라가고, cmd-docu 밖(옵시디언 등)에서도 그냥 열린다.
- **자동 메타데이터**: 노트를 처음 만들 때 AVFoundation으로 **재생하지 않고도** 길이·포맷·생성일·내장 제목을 읽어 frontmatter에 채운다. 나머지(왜 중요한지 등)는 사람이 메모로 채운다.
- **화면**: 동영상=좌우 분할(플레이어/노트), 음악=상단 재생바+아래 노트. 미리보기⇄편집 전환, 노트 없으면 "메모 만들기" 버튼(레이스 안전).
- **목록·검색**: 짝꿍 노트는 목록에서 숨기고 미디어 행에 배지+한 줄 요약 부제로 존재를 표시한다. 노트도 마크다운이라 기존 내용 검색 색인에 자동으로 들어간다 — 몇 달 뒤 파일명이 아니라 그때 적어 둔 메모 문구로 그 음원/영상을 찾아낼 수 있다.
- **안전장치**: 원본 미디어 파일은 절대 바꾸지 않는다(쓰기는 짝꿍 `.md`뿐). 새 패키지 의존성 0(AVKit/AVFoundation은 시스템 제공).
- **실사용 수정**: SPM 실행 파일에서 SwiftUI `VideoPlayer`를 쓰려면 `AVKit.framework`를 명시적으로 링크해야 한다(자동 링크만으론 즉시 종료) — `Package.swift`에 반영. 창 닫기(메뉴바 상주 앱이라 창이 파괴 안 됨)·탭 전환 시 재생 상태 관리를 소유권 정리(탭당 단일 공유 플레이어)로 수정.
- 우선순위: 완료 / 티어 2 (2026-07-02, Phase 8.6)

### 3.14 빠른 파인더 — 못 여는 파일도 애플 미리보기로 (조각 A)

- **배경**: 사용자 요청으로 앱에 축을 하나 더 세웠다 — "빠른 파인더 + 미리보기 앱". 지금도 파인더를 여는 순간은 ①옮기고 정리 ②앱이 못 여는 파일을 볼 때 ③특정 위치로 이동할 때다. 남은 일을 다섯 조각(A~E)으로 나눴고, 이 항목은 그 첫 조각(A)이다. 나머지(D+B=기본 위치·보내기, C=두 폴더 나란히, E=폴더 전환 매끄럽게)는 후속.
- **조사가 뒤집은 전제**: `.pptx`·`.zip`·`.json`처럼 앱이 모르는 형식은 열면 깨진 글자가 뜨는 게 아니라, **트리·라이브러리 목록에 애초에 나타나지도 않았다**(허용 목록 방식). 그래서 문제를 "목록에 안 보임" + "눌러도 못 엶" 두 겹으로 다시 정의했다.
- **설명**: 판정 규칙(`QuickLookRouting`) 하나로 "이 파일을 글로 열까 / 애플 미리보기(QuickLook)로 넘길까"를 정하고, 목록 필터·검색 색인이 전부 이 규칙 하나를 재사용한다. (1) 목록은 이제 **모든 파일**을 보여준다(숨김 파일은 설정에서 켜고 끄는 옵션, 기본 꺼짐). (2) 모르는 형식은 탭에서 맥 기본 미리보기(QLPreviewView)로 열리고, 위쪽에 "OO 앱으로 열기"·"글로 열기"(맥이 "글자 아님"이라 잘못 판단한 `.mdx` 등 구제) 버튼을 둔다. (3) 파일을 고르고 스페이스바를 누르면 큰 화면으로 훑어보는 빠른 보기가 뜨고, 다시 스페이스바·esc로 닫히고 ←→로 다음/이전 파일로 넘어간다. (4) json·swift·csv 같은 글자 파일도 이제 내용 검색 대상에 포함된다(5MB 넘는 파일은 이름만 색인).
- **설계 결정 — 시트가 아니라 오버레이**: 스페이스바 빠른 보기 화면은 macOS의 "시트"(모달 창)가 아니라 화면 위에 얹는 오버레이로 만들었다. 떠 있는 시트가 앱 종료 자체를 막는다는 것을 이달 자동 업데이트 사고(§3.12)에서 실측으로 확정했기 때문에, 같은 문제가 재발하지 않는 방식을 처음부터 골랐다.
- **키보드 안전장치**: 검색창 등에 글자를 입력하는 중이면 스페이스바는 그냥 띄어쓰기로 동작하고 빠른 보기를 가로채지 않는다(이 저장소에서 반복됐던 "키 단축키 가로채기" 결함 패턴 재발 방지 — 미리보기 화면 안에서도 같은 가드 적용).
- **진행 방식**: 7단계로 나눠 순서대로 구현 — 단계마다 만들고 별도 검토를 거쳐 테스트 확인 후 커밋, 마지막에 전체를 통째로 다시 점검. 그 마지막 점검에서 실제로 이어붙임 결함 3건(미리보기 화면 안 단축키 가로채기 가능성·검색이 폴더 자체를 문서처럼 잘못 색인·숨김파일 설정이 사이드바 트리엔 안 먹히던 것)을 찾아 바로 고쳤다. 872개 테스트 전부 통과.
- **원본 불변**: 이 작업의 어떤 경로도 사용자 파일을 쓰거나 지우지 않는다. 새 패키지 의존성 0(QuickLook·UniformTypeIdentifiers는 시스템 제공).
- 우선순위: 완료(구현) / 실기 확인 대기 / 티어 3 (2026-07-25, Phase 12)

## 4. 기술 아키텍처

### 4.1 기술 스택

- 앱: Swift 5.9+ / SwiftUI (원본 유지), Swift Package(SPM), macOS 14+
- 문서 엔진: Node 18+ / kordoc CLI (서브프로세스 호출)
- 검색 인덱스: SQLite FTS5 (macOS 기본 내장)
- 추가 프레임워크(모두 macOS 기본): PDFKit(PDF 보기), ImageIO/AppKit(이미지), Foundation `Process`(CLI 호출), `FileManager`(이동/이름변경)
- 원본 의존성 유지: swift-markdown · Highlightr · Yams · Mermaid·KaTeX (원본은 CDN → **Phase 8.7에서 highlight.js와 함께 로컬 번들로 전환**)

### 4.2 외부 도구/데이터 소스

| 도구/소스 | 용도 | 키 필요 | 비고 |
| --- | --- | --- | --- |
| 로컬 `kordoc` CLI | HWP/오피스/PDF 읽기·쓰기·양식·패치 | 불필요 | Node 18+ 필요. MIT |
| 로컬 `claude` CLI | Claude 질의·라우팅·정리·RAG | 불필요(구독) | Claude Code 로그인 선행. Agent SDK 크레딧 차감 |
| SQLite FTS5 | 내용 검색 인덱스 + RAG 근거 회수 | 불필요 | macOS 내장. `trigram` 토크나이저(한국어 부분일치), ≤2글자 `LIKE` 폴백 |
| Mermaid/KaTeX (+highlight.js) | 다이어그램·수식·코드 색칠 | 불필요 | 원본은 CDN → **Phase 8.7에서 로컬 번들화** |

### 4.3 프로젝트 구조 (원본, Phase 0에서 실제 확인)

```
CmdMD/
├── Package.swift          # SPM 매니페스트
├── Sources/               # Swift/SwiftUI 소스 (앱 본체)
├── Tests/CmdMDTests/      # 테스트 57개
├── Resources/  docs/  landing/  scripts/
└── LICENSE (MIT)
```

신규 기능은 `Sources/`의 "파일 종류 → 뷰 디스패치" 한 곳을 중심으로. 마크다운=기존 렌더러, PDF=PDFKit, 이미지=이미지 뷰, HWP/오피스=kordoc→마크다운 렌더. 정확한 위치는 Phase 0에서 특정.

## 5. 데이터 모델

별도 서버·외부 DB 없음. 모든 입력은 로컬 파일.

```
DocumentKind:  markdown | pdf | image | office | media | quickLook   # office = kordoc 경유 렌더, media = 음악·동영상(AVKit), quickLook = 모르는 형식(애플 미리보기)
CompanionNote: 미디어 파일 옆 `파일명.ext.md` 짝꿍 노트 — frontmatter(길이·포맷·생성일 자동) + 자유 메모, DB 아님
SearchIndex (SQLite FTS5, trigram):  { path, title, bodyMarkdown, mtime, kind }
RouteSuggestion:  { folder, filename?, reason }          # 노트 1건 분류
CleanupPlan:      [ { from, to, action: move|rename, reason } ]
MainMode:         reader | library                       # 메인 영역 모드(리더/라이브러리)
LibraryLayout:    list | grid                            # 폴더별 표시 기억(URL→layout)
RagSource:        { index, path, snippet, location(line|page|unknown) }  # RAG 근거 — [n] 클릭 시 줄/페이지 점프(오피스는 파일 열기)
UpdateProgress:   idle | downloading(비율) | verifying | installing | readyToRelaunch | failed(사유)
UpdateInstallError: 쓰기권한없음 | 다운로드실패 | 체크섬불일치 | 해제실패 | 번들검증실패 | 교체실패(원복됨) | 교체실패(백업남음)
```

- Claude 응답은 영구 저장하지 않음(세션 표시 + 노트 삽입 옵션). 보관은 claude.ai가 아니라 볼트 마크다운으로.
- 폴더 정리 실행 시 이동 로그(from→to)를 남겨 undo. 삭제 없음.
- 검색 인덱스는 파생물(재생성 가능). 원본은 불변, 인덱스만 생성.

## 6. 개발 단계 (우선순위 3티어)

### 티어 1 — 당장 (리더 코어)

**Phase 0: 포크 준비 & 아키텍처 파악**

- [x] 포크·클론, `swift build`/`swift run` 빌드 확인, `swift test`로 기존 테스트 57개 기준선 확보

- [x] 소스 읽기 — 파일 열기/탭/프리뷰 디스패치 위치 특정. 프리뷰가 WebView 기반인지 코드로 검증(추정 금지)

- [x] 표시명 cmd-docu로 교체, 번들 ID는 역도메인 형식(예: work.cmdspace.cmddocu — 하이픈 회피). LICENSE·원작자 고지 유지

**Phase 1: 이미지 리더** — 디스패치에 image 분기, 뷰 구현, 줌/팬, 최소 테스트

**Phase 2: PDF 리더 (PDFKit)** — `PDFView` 래핑, 탭 표시, 페이지/검색/선택·복사/줌/회전. (썸네일 칸은 시도했으나 결함 발견 후 제거 — §3.1 2026-07-25 버그 수정 참고.)

**Phase 3: 한글·오피스 읽기 (kordoc)**

- [x] Node/kordoc 존재 확인(`npx kordoc` 경로 탐지), 미설치 안내

- [x] 디스패치에 office 분기 — `npx kordoc <파일> --format json` 호출 → markdown 수신 → 기존 렌더러로 표시

- [x] HWP3/5·HWPX·HWPML·XLS/XLSX·DOCX 열기 확인, 표/이미지 렌더 점검

### 티어 2 — 다음 (Claude + 생성)

**Phase 4: Claude 연동 (claude -p)**

- [x] `claude` 바이너리 경로 탐지, 미설치/미로그인/크레딧소진 메시지 분기

- [x] 커맨드 팔레트 + 단축키로 "Claude에게 질문" 진입점, 문서 본문 동봉 전달, 응답 패널 표시

- [x] 응답을 노트에 마크다운으로 삽입/볼트 저장(보관은 볼트로)

**Phase 5: 한글·오피스 쓰기 (kordoc)**

- [ ] ~~md → HWPX 생성(kordoc generate, 공문서 프리셋/글꼴/크기 옵션)~~ — kordoc에 generate 없음(Phase 5a 실측)으로 취소

- [x] 무손실 패치(`kordoc patch`) — 원본 서식 보존 텍스트 교체

- [x] 양식 자동 채우기(`kordoc fill`) — 라벨-값 매칭, 서식 보존

**Phase 6: 스마트 라우팅 (PARA 분류)**

- [x] 설정에 PARA 목적지 목록(레고 구조 시드)

- [x] 보내기에 "Claude에게 맡기기" 분기 → `RouteSuggestion` 수신 → 확인 → 기존 이동 로직

- [x] 자동 라우팅에 Claude 끼우기 옵션(기본 OFF)

### 티어 3 — 나중/선택 (검색·정리·시맨틱)

**Phase 7: 내용 검색 (Docufinder식, 키워드)**

- [x] 폴더 등록 → kordoc 파싱 → SQLite FTS5 인덱싱(본문 마크다운)

- [x] 키워드 검색 + Everything식 파일명 검색, 결과 미리보기/열기

- [x] 파일 감시로 추가/수정 자동 재인덱싱

**Phase 8: 폴더 정리 (배치)** — 폴더 선택 → 메타데이터(+모호 파일만 내용) → `CleanupPlan` → 미리보기·승인 → `FileManager` 이동, 로그·undo

**Phase 8.5: PARA 라이브러리 뷰 (리더 ⇄ 라이브러리)** — `AppState.mainMode`(reader/library) + `MainEditorView` 분기 + 툴바 모드 세그먼트(하위토글 Source·Split·Preview ⇄ List·Grid). `selectedFolder` 선택 개념 신설(**Phase 8과 공유** — 폴더 선택·미리보기 기반 재사용). detail에 `LazyVGrid`/`List`(썸네일=QuickLook `QLThumbnailGenerator` lazy+`NSCache`). 사이드바 PARA 렌즈(`legoSeed` 그룹·Archive dim·Projects 또렷). 폴더별 뷰 기억(URL→layout). 클릭이 모드 견인+토글 우선. **읽기 전용(이동은 Phase 8 몫)**. 단계: ①PARA 렌즈 → ②메인 그리드+모드토글 → ③뷰 기억·다듬기.

**Phase 8.6: 미디어 플레이어 + 짝꿍 노트** — **완료(2026-07-02)**. 상세는 §3.13. 순서: ①본다(플레이어+짝꿍 노트 표시, 없으면 "메모 만들기") ②쓴다(메타데이터 자동 채움·Inspector에서 편집) ③찾는다(목록 배지+검색 색인 통합). 실파일 수동 스모크가 결함 3건 포착·수정(AVKit 프레임워크 명시 링크 누락으로 즉시 종료가 가장 심각).

**Phase 8.7: 미리보기 속도 다듬기** — 코드 검증(2026-06-30, 5렌즈)으로 확정된 것만. **8.5 다음·9 앞**, 작업 전후 `swift test` 통과 확인. 신규 분은 별도 파일/모듈로 분리.

- [x] **highlight.js 로컬화(최우선·거의 공짜)** — `MarkdownRenderer.hljsIncludes()`(`MarkdownRenderer.swift:657`)가 매 렌더 `cdn.jsdelivr.net/gh/highlightjs/cdn-release@11`을 로드. **highlight.js는 이미 `Highlightr_Highlightr.bundle`(1MB JS + github/github-dark CSS)로 동봉**돼 있으니 CDN 대신 그 번들을 읽어 `<script>` 인라인 주입(lazy static 캐시로 매 렌더 I/O 방지). `loadHTMLString` baseURL 유지. `SyntaxHighlighter.highlightrResourceBundleIsPresent()`의 번들 탐색 로직 재사용(`swift run`·패키지 경로 둘 다).

- [x] **THIRD-PARTY-NOTICES.md 정정** — highlight.js가 현재 §1·§2·§3 어디에도 **누락**(CDN 상태인 지금도 고지 의무 미이행). highlight.js(Ivan Sagalaev, MIT) 항목 추가. 로컬화 후 §2→§1 이동 + MIT 저작권 줄. Highlightr(기저=highlight.js) 비고로 중복 혼동 방지.

- [x] **파일 트리 백그라운드화** — `AppState.buildFileTree`(`AppState.swift:1110`)가 `contentsOfDirectory`를 메인 스레드 동기 재귀(depth 10, 펼친 폴더만). 스캔을 `Task.detached`(이미 `AppState:702` 패턴 존재)로 옮기고 `await MainActor.run`으로 `fileTree`만 반영. **선행 task `.cancel()`로 연타 레이스 방지**, `expandedFolders` 스냅샷 캡처, Sendable·@Observable 메인스레드 대입 주의.

- [ ] ~~(보류) 미리보기 DOM 부분 갱신(A-3)~~ — 검증 결과 **이미 250ms 디바운스 존재**(`PreviewView.swift:139`)·스크롤 보존. 통째 reload는 맞으나 실익은 깜빡임 제거뿐이고 JS 재초기화·체크박스 리스너·evaluateJavaScript 레이스 리스크가 커 **보류**. (실제 병목이 Swift측 `renderToHTML` 전처리라면 별도 검토.)

- [x] KaTeX/Mermaid 로컬화 — 완료(2026-07-02) — vendoring 스크립트+SPM 리소스, katex 0.16.47·mermaid 11.16.0 인라인 주입+CDN 폴백, KaTeX 폰트 woff2 data-URI.

**Phase 9: 자료에 묻기 — 가벼운 RAG (LLM-Wiki 질의층)** — **완료(2026-07-01, §3.11)**. 원안(임베딩·벡터·하이브리드)을 **B안(임베딩 없이 FTS5 근거 + Claude 답변)** 으로 재정의해 구현 — 질의 확장 OR 재검색 → 근거 회수 → 패시지 추출 → Claude 답변(`[n]` 출처, 클릭 시 문서 위치 점프), 근거 0건이면 답변용 Claude 호출 생략. 후속으로 **한국어 검색 근본 수정**(FTS5 `unicode61`→`trigram` 전환 + ≤2글자 `LIKE` 폴백 + 구 인덱스 자동 마이그레이션·등록 폴더 재인덱싱 — Phase 7 키워드검색·Phase 9 RAG 공통 개선)까지 반영. 시맨틱·임베딩(A안)은 선택 후속(§3.11 후속 참고).

**Phase 10: 다듬기 & 배포** — 단축키·설정 정리, `package_app.sh` 패키징·ad-hoc 서명·격리 해제, README 포크판 갱신(출처·라이선스) — **완료(2026-07-02)**: cmdALL 겉면 개명·단축키 4종·Tools 설정 탭·0.9.0 DMG·README 갱신.

**Phase 11: 앱 내 자동 업데이트** — **완료(2026-07-25, §3.12)**. 순수 헬퍼(진행 상태·오류·자산 URL·체크섬 파싱) → 원자적 교체기(실패 시 원복·휴지통) → 오케스트레이터(actor, 네트워크·서명 검증 프로토콜 주입) → `AppState` 배선·UI 순으로 4태스크 TDD. 실제 릴리스를 상대로 전 과정 실측(진행률 8%→100%·체크섬·codesign·교체·잔여물 0), 실행 중 앱의 이름 변경·휴지통 이동도 실측. v0.9.404→409로 실기 검증.

- [x] 릴리스 자산 URL·`SHA256SUMS.txt` 파싱·한국어 오류 문구(순수)
- [x] 원자적 번들 교체 — 백업→교체, 2단계 실패 시 즉시 원복, 옛 번들 휴지통
- [x] 다운로드(진행률 델리게이트)·SHA-256 대조·`ditto` 해제·번들 검증(버전+codesign)
- [x] 상태 표시줄 알약·About 버튼 배선, 재시작 예약(`applicationWillTerminate`에서만 실행)
- [x] **실사용 사고 수정** — 떠 있는 시트가 `NSApp.terminate`를 막는 것을 최소 재현·변이 시험으로 확정 → 시트를 먼저 닫고 종료, 2초 내 미종료 시 안내 + 예약 해제. 버튼이 링크 색을 잃어 평범한 글씨로 보이던 것도 수정
- [x] 배포 안내 정정 — 패키징에 번들 리소스 쓰기 권한 부여(`xattr -dr`이 실제로 듣게), README에 curl 설치(`install_latest.sh`) 최우선 안내 신설

**Phase 12: 빠른 파인더 — 못 여는 파일 미리보기(조각 A)** — **완료(2026-07-25, §3.14)**. 계획 7단계를 순서대로 — ①`QuickLookRouting`(단일 판정 규칙)+`DocumentKind.quickLook` ②목록 허용 목록 제거(전부 표시)+숨김 파일 옵션 ③탭용 미리보기 화면(`QLPreviewView`+기본 앱 열기) ④"글로 열기" 전환 ⑤스페이스바 키 라우팅 ⑥빠른 보기 오버레이(시트 아님) ⑦글자 파일 검색 확장. 단계마다 구현→별도 검토→테스트→커밋, 마지막에 전체 재점검. v0.9.410으로 GitHub 릴리스 발행 완료, 재설치 후 사용자 실기 확인 완료.

- [x] 목록 필터·검색 색인·"여는 방식" 판정을 `QuickLookRouting` 하나로 통일(전엔 각자 다른 확장자 목록을 따로 갖고 있어 서로 어긋났었다)
- [x] 재점검에서 이어붙임 결함 3건 발견·수정 — 미리보기 화면 안에서 단축키가 잘못 가로채질 수 있던 것(`responderYieldsFileKeys`에 QLPreviewView 추가), 검색이 폴더 자기 자신까지 문서처럼 색인하던 것(실제 파일만 걸러내게 수정), 숨김 파일 설정이 사이드바 트리엔 안 반영되던 것
- [x] 872개 테스트 전부 통과, 빌드 경고 0
- [x] **수동 스모크 완료** — 재설치 후 pptx/zip/psd 열기·"OO으로 열기" 버튼·`.mdx` 글로 열기·스페이스바 열고닫기+←→ 넘기기·검색창 타이핑 중 스페이스 정상 동작(키 강탈 회귀 없음)·숨김 파일 토글·json 내용 검색 — 전부 사용자 실기 확인
- [x] 원격(GitHub)에 v0.9.410으로 릴리스 발행 완료

**Phase 13: 빠른 파인더 — 기본 위치 + 빠른 이동(D+B)** — **완료(2026-07-25, §10)**. 계획 4단계 — ①`QuickMoveFolder` 모델+`AppState` 등록/해제/저장 ②단축키 `⌥⌘M` ③사이드바에 홈·데스크탑·다운로드·문서 고정 표시(D) ④폴더 우클릭 "빠른 이동 목록에 추가" 등록 토글+`QuickMoveSheet`+File 메뉴·단축키·우클릭 메뉴 배선(B). 이동 실행은 F1b가 만든 `performBatchMove`(로그+되돌리기)를 그대로 재사용 — 새 이동 로직 없음. 즐겨찾기와는 별개 저장소로 분리(2026-07-25 사용자 결정 — 자동 병합 대신 직접 등록 방식). v0.9.411로 GitHub 릴리스 발행 완료.

- [x] `QuickMoveFolder` 등록·해제·중복 방지·재시작 후 유지·존재하지 않는 경로 필터링(10개 테스트)
- [x] 사이드바 Favorites 탭에 기본 위치 4개 고정 표시, 클릭 시 폴더 전환
- [x] 폴더 우클릭(트리·라이브러리·즐겨찾기·기본 위치 전부)에서 빠른 이동 목록 등록/해제 토글
- [x] `⌥⌘M`·File 메뉴·우클릭 메뉴 "빠른 이동…"으로 시트 호출, 목적지 클릭 시 즉시 이동, 목록 비었을 때 "다른 폴더로 이동…"으로 대체 가능
- [x] 864개(XCTest) + 18개(Swift Testing) 테스트 전부 통과, 빌드 경고 0
- [x] 재점검(설계 §7 4항목) 완료 — 이동 후 목록 자동 갱신(`performBatchMove` 기존 경로 재사용 확인), 제자리 이동 skip 시 조용히 닫히는 것은 기존 "폴더로 이동…"과 동일한 기존 동작(신규 이슈 아님), 등록 목록과 즐겨찾기가 저장소째 분리돼 안 섞임(코드 확인), 다중 선택 시 `fileSelection` 전체가 대상(테스트로 확인)
- [x] **수동 스모크 완료(2026-07-27, 사용자 실기 확인)** — ⌥⌘M 빠른 이동 정상 동작 확인.
- [x] 원격(GitHub)에 v0.9.411로 릴리스 발행 완료(dmg·zip·SHA256SUMS.txt).

## 7. UI/UX 가이드

- 데스크탑 전용. 원본의 "리뷰 우선·키보드 중심" 톤 유지.
- 문서 종류가 바뀌어도 탭·사이드바·단축키 경험은 일관. PDF·이미지·HWP·오피스 모두 마크다운처럼 탭으로 열고 닫음.
- Claude 패널·검색 패널은 토글 가능한 보조 영역. 읽는 문서를 가리지 않게.
- 라우팅·정리·검색의 파일 변경은 항상 미리보기/확인을 거친다.
- 리더(파일 한 장 줌인)와 라이브러리(폴더 펼쳐 줌아웃)는 같은 "현재 폴더"를 공유하는 두 시점. 전환은 토글, 클릭이 기본 견인.
- 색·테마는 원본 CMDS 라이트/다크 유지.

## 8. LLM-Wiki 연동 (운영 패턴 — 앱 밖)

- Karpathy LLM-Wiki 패턴은 "앱에 넣는 것"이 아니라 **Claude Code + 볼트 안 CLAUDE.md 스키마**로 굴린다. 위키 = 볼트의 마크다운 파일.
- 이 앱의 역할은 그 위키의 **뷰어 + Ingest/Query 손잡이**다. 3.5(Claude 연동)·3.6(라우팅)·3.7(내용검색)·3.11(RAG)이 각각 Query·Ingest·소스검색·근거 기반 질의응답에 대응한다.
- 별도 산출물: 레고 PARA에 맞춘 **볼트용 LLM-Wiki 스키마(CLAUDE.md)** — 앱 개발용 CLAUDE.md와는 다른 파일. 요청 시 작성.

## 9. 제약 사항 및 주의점

**라이선스**

- CmdMD: MIT — 포크·수정·재배포 자유, LICENSE·원작자 고지 유지.
- kordoc: MIT — 엔진으로 직접 사용 가능.
- **Docufinder: BSL 1.1 — 코드 차용 금지.** 아이디어/아키텍처만 독립 구현하고, 실제 엔진은 kordoc으로 대체한다. (2030-04-15 Apache 2.0 자동 전환 전까지 프로덕션 사용은 별도 라이선스 필요)
- 원본 CmdMD가 활발히 개발 중이라 포크는 갈라진다. 신규 기능은 별도 파일·모듈로 분리해 업스트림 머지 용이성 확보.

**파일 이동 안전(라우팅·정리 공통)**

- Claude는 제안만. 레고 승인 없이 어떤 파일도 이동/이름변경 금지(자동은 기본 OFF).
- 이동·이름변경만, 삭제 없음. 실행분은 로그로 undo.
- 건강·정치 자료가 섞인 지식베이스이므로 보수적으로.

**Claude 비용·보안**

- 사용량은 월간 Agent SDK 크레딧 차감(한도·비이월·개인용). 소진 시 중단 또는 API 요금.
- `claude -p`에 보내는 본문은 Claude로 전송됨. 민감 문서는 전송 전 인지.
- 개인용. 포크를 여러 사람이 쓰게 배포 금지(구독 하나로 다수 트래픽 불가).

**기술**

- 비샌드박스 유지(샌드박스면 `Process` CLI 호출 막힘). **자동 업데이트도 비샌드박스·`LSFileQuarantineEnabled` 미설정이 전제** — 샌드박스로 바꾸거나 그 키를 켜면 앱이 받은 파일에도 격리가 붙어 Gatekeeper 차단이 되살아난다(§3.12).
- **ad-hoc 서명(비공증)의 대가**: 브라우저·AirDrop·메시지로 받은 배포본은 항상 격리 표시가 붙어 "악성 코드 확인 불가"로 차단된다. 해소는 ① 앱 내 업데이트(격리 없음) ② `scripts/install_latest.sh` curl 설치 ③ `xattr -dr` 수동 해제. Apple Developer ID 서명·공증(연 $99)을 도입하면 근본 해소되며, 지금 구조는 공증을 나중에 붙여도 그대로 쓸 수 있다(`release.yml`에 `HAS_SIGNING` 경로 예비됨).
- Node 18+ 필요(kordoc). LibreOffice보다 가벼움.
- kordoc HWP5 쓰기는 패치(텍스트)만, 새 문서는 HWPX. 한글 충실도는 레고 실파일로 먼저 테스트.
- 내용 검색(티어 3)은 규모가 커서 분리. 키워드(FTS5)는 Phase 7, RAG는 Phase 9에서 임베딩 없이(B안) 구현 완료. 시맨틱·임베딩(A안)은 선택 후속.
- Phase마다 `swift test`로 기존 테스트 유지 확인 후 진행. 추정을 사실로 적지 않음.

---

## 10. 다음 예정 작업 (2026-07-25 논의, 아직 착수 전)

**"빠른 파인더" 로드맵 나머지 조각** — A·D+B·C 완료·배포. 순서는 A → D+B → C → E.

- **D+B**(작은 일, Phase 13) — v0.9.411로 GitHub 릴리스 발행 완료. **수동 스모크 완료(2026-07-27)** — ⌥⌘M 빠른 이동 확인됨.
- **C**(큰 일, 기존 로드맵 F4): 폴더 두 개를 나란히 놓고 보기. **구현 완료(2026-07-29)** — 아래 "조각 C" 상세 참고. **수동 스모크 대기.**
- **E**(먼저 다시 살펴보고 필요할 때만): 폴더를 오갈 때 화면 전환을 더 매끄럽게. 아직 착수 전.
- 각 조각은 지금까지 해 온 대로 설계→계획→구현 순서를 따른다.

**조각 C(두 폴더 나란히 보기) — 구현 완료(2026-07-29), 실기 확인 대기**:

- 켜고끄기 버튼 토글로 화면을 두 칸으로 나눠 폴더를 각각 독립적으로 펼쳐본다. 사이드바는 하나를 공유하고 포커스된 칸이 타겟이 된다. 칸 사이 파일 이동은 드래그로만(F2 이동 로직 재사용, 로그·undo 그대로 적용). 칸 안에서 파일을 클릭하면 읽기 전용 미리보기만 뜨고, 제대로 열려면 "이 창에서 제대로 열기" 버튼을 눌러 기존 탭으로 연다.
- 설계·계획 문서: `docs/superpowers/specs/2026-07-29-dual-pane-design.md` · `docs/superpowers/plans/2026-07-29-dual-pane.md`. 신규 파일: `BrowsePane`(모델) · `DualPaneView`/`PaneView`(레이아웃) · `PaneReaderView`(칸 안 읽기 전용 미리보기) · `DualPaneToggleButton`. 7단계로 나눠 구현·커밋(§CLAUDE.md 참고), 마지막 단계에서 전체 회귀 확인 + 재패키징까지 완료.
- **수동 스모크 대기** — 실제로 두 폴더를 켜서 나란히 훑어보고, 드래그 이동·읽기 전용 미리보기·"이 창에서 제대로 열기"가 실기에서 정상 동작하는지 확인 필요.

**조각 A(Phase 12) — 완료(2026-07-25)**:

- 재설치 후 손으로 눌러보는 확인(pptx·zip·psd 열기, "OO 앱으로 열기" 버튼, `.mdx` "글로 열기", 스페이스바 열고닫기+←→ 넘기기, 검색창 타이핑 중 스페이스 정상 동작, 숨김 파일 토글, json 내용 검색) — 사용자 실기 확인 완료.
- 원격(GitHub)에 v0.9.410으로 릴리스 발행 완료.

**조각 A 마지막 재검사에서 나온, 급하지 않은 사소한 후속**:

- 심볼릭 링크로 연결된 파일은 폴더 내용 색인에서 예외로 빠진다(흔치 않은 경우).
- 기존에 있던 "폴더 안에서 바로 검색"(사이드바 즉석 검색)은 여전히 md·txt만 본다 — 새로 넓힌 내용 색인(FTS5)과는 다른 경로라 자동으로 같이 넓어지지 않았다.
- 1회성 백그라운드 재색인이 도는 동안 진행 표시가 안 뜬다(동작엔 문제없음, 다듬을 여지만 있음).

**전역 단축키 파일 찾기 (Raycast식) — 완료, 실기 확인 완료(2026-07-27)**

- **배경**: 사용자가 "라이캐스트처럼 전역 단축키로 파일 찾기를 띄우고 열게 하고 싶다"고 요청.
- **조사 결과(중요)**: 타이핑해서 파일 찾고 엔터로 여는 기능 자체는 **이미 완성돼 있음**(⇧⌘O
  Omnisearch — 파일명 퍼지매칭 + 최근 파일 + 내용검색 + 엔터로 새 탭 열기, `OmnisearchView`·
  `OmnisearchModel`). 없는 건 딱 하나 — 그 검색창이 cmdALL 창 안에서만 뜨고, **다른 앱을 보고
  있을 때 단축키로는 안 뜬다**는 것.
- **재사용 가능한 기존 인프라**: 진짜 전역(다른 앱 위에서도 반응하는) 단축키 자체는 이미 한 개
  있음 — ⇧⌘M(`AppDelegate.applicationDidFinishLaunching`의
  `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`, Quick Capture용). 같은 방식을
  재사용해 새 조합을 등록하면 됨.
- **새로 만들 것**: ① 다른 앱 위에 둥실 뜨는 독립 검색창(NSPanel, 화면 중앙, 항상 위) —
  안에 기존 `OmnisearchView`를 그대로 담음. ② 그 창을 부르는 새 전역 단축키(기본값 제안:
  ⌃⌘Space — 다른 런처 앱들과 안 겹치는 조합, 설정에서 바꿀 수 있게 기존 KeyBinding 시스템
  재사용). ③ 엔터 시 cmdALL이 앞으로 나오며 새 탭으로 파일 열림 + 검색창 닫힘. Esc 시
  그냥 닫히고 원래 보던 앱으로 복귀(cmdALL이 강제로 앞에 나서지 않음).
- **주의사항(사용자에게 미리 고지 완료)**: 다른 앱을 보고 있어도 단축키를 알아채려면 macOS가
  최초 1회 "손쉬운 사용" 권한을 물을 수 있음(Raycast·Alfred도 동일). 거부해도 이 기능만
  안 되고 나머지 앱 기능엔 영향 없음 — 설정 화면에 짧은 안내 문구 추가 예정.
- **이번엔 안 할 것(범위 제외 합의)**: 검색창 안 파일 미리보기(썸네일), 등록 안 한 폴더까지
  전체 디스크 뒤지기, 계산기·클립보드 등 Raycast의 다른 커맨드 기능.
- **상태**: 사용자 승인("단축키 가자") 후 구현. 두 번 조합을 바꿨다 — ①처음 제안 ⌃⌘Space는
  macOS 자체 "이모지 및 기호" 기본 단축키와 겹칠 위험이 커 ⇧⌘Space로 1차 변경. ②사용자가
  "커맨드+시프트+8로 해줘"라고 재지정해 **최종 ⌘⇧8**로 확정 — 기존 ⌘⇧8("검색 통합(방법2)"이
  붙인 조합, cmdALL 메인 창 전체를 앞으로 불러와 시트로 검색을 열던 방식)을 이 오버레이가
  그대로 대체했다(한 조합에 동작 두 개를 둘 수 없어 옛 동작·알림·옵저버 제거). 구현:
  `GlobalSearchOverlayController`(신규, 독립 `NSPanel` + `.nonactivatingPanel`로 cmdALL을
  활성화하지 않고 화면 중앙에 기존 `OmnisearchView` 재사용) + `AppDelegate`에 전역·로컬
  단축키 두 곳 배선(다른 앱 포커스 중·cmdALL 포커스 중 모두 반응) + 설정에 켜고 끄기
  토글(Tools 탭, 기본 ON) + 접근성 권한 안내 문구. 리매핑(다른 키 조합으로 바꾸기)은 이번
  범위에서 뺐다 — 기존 ⇧⌘M도 리매핑이 안 되는 것과 일관되게 고정 조합으로 뒀다(과한 설계
  방지). `swift build`·`swift test`(929개) 통과.
- **실사용 사고·수정(2026-07-27, v0.9.414 재설치 직후)**: 사용자가 "전역 단축키 안 듣는다"고
  보고 — 진단해보니 cmdALL 창이 앞에 있을 때는 검색창이 뜨는데(코드 정상), **다른 앱이
  앞에 있을 때만** 반응이 없었다. 원인은 macOS의 "손쉬운 사용(Accessibility)" 신뢰 — 이
  앱은 애플 정식 인증서 없이 ad-hoc 서명이라 **빌드할 때마다 서명이 바뀌고**, macOS가 예전
  서명 기준으로 저장해둔 신뢰 기록이 새 빌드와 안 맞아 무효화된다(`tccd` 로그에
  `Failed to match existing code requirement` 실측 확인). 시스템 설정에서 토글 껐다 켜기로도
  안 고쳐져 `tccutil reset Accessibility work.cmdspace.cmddocu`로 깨진 기록을 완전히
  지우고 재등록하게 해 해결. **재발 방지 코드 추가** — `AppDelegate.
  requestAccessibilityTrustIfNeeded()`(`applicationDidFinishLaunching`에서 호출)가 신뢰가
  없으면 macOS 표준 "손쉬운 사용에 추가해 달라" 팝업을 직접 띄운다(이전엔 조용히 실패만
  하고 사용자가 원인을 알 방법이 없었다). `swift test` 929개(회귀 없음).
- **v0.9.415로 재확인(같은 날)**: 새 빌드가 깔리자 서명이 또 바뀌어 허가가 다시 풀리는 것까지
  실측으로 재현됨 — 예상대로 **정식 인증서 없는 한 버전마다 반복되는 구조적 문제**로 확정.
  `tccutil reset` 재실행 → 새로 추가한 팝업이 실제로 뜨는 것 확인 → 사용자가 체크 →
  **"다시 된다" 확인 완료.** 다음 버전부터도 이 팝업이 매번 안내는 해주되, 체크는 그때그때
  사용자가 다시 눌러야 한다(근본 해결은 애플 정식 개발자 인증서 도입 — 선택 후속, 비용 발생).

**Docufinder("Anything", chrisryugj/Docufinder) 대비 기능 격차 — 2026-07-27 조사**

- 사용자가 "이것처럼 되고 싶다"며 참고자료로 제시. Docufinder는 cmdALL 기획 초기부터 아이디어
  참고 대상이었음(BSL 라이선스라 코드 차용은 금지, §1·§3.7 참고).
- **이미 cmdALL에도 있어 겹치는 것**: 폴더 등록 시 자동 본문 색인 + 내용 검색, 파일 변경 시
  자동 재색인(실시간 동기화), 한글(HWP/HWPX)·워드·엑셀·PDF 읽기, 자료 근거 기반 AI
  질의응답(RAG, §3.11) — Docufinder의 "AI 질의응답"과 동급.
- **Docufinder에는 있는데 cmdALL엔 없는 것(구체적 격차 7가지, 우선순위 미정)**:
  1. 파일명 검색 결과를 정렬 가능한 표(이름·경로·크기·수정일·종류 칼럼, 너비 조절)로 보기 —
     cmdALL은 지금 단순 리스트(Omnisearch).
     — **완료(2026-07-27, 1단계)**: 설계·계획 승인 후 구현. `Sources/Models/OmnisearchHit.swift`(신규,
       옛 `OmnisearchView.Hit`을 최상위 모델로 승격 + `sizeBytes`/`modifiedAt` 필드 추가)·
       `Sources/Models/OmnisearchSort.swift`(신규, 정렬 키+방향 상태)·
       `Sources/Services/OmnisearchHitSorting.swift`(신규, 순수 정렬 함수)·
       `Tests/CmdMDTests/OmnisearchSortTests.swift`(신규, 정렬 로직 단위 테스트 6개)·
       `Sources/Views/OmnisearchView.swift`(칼럼 헤더+클릭 정렬, 칼럼 폭 드래그 조절, 파일 행을
       이름/경로/크기/수정일 4칸 표로 교체, 팝업 프레임 760×480으로 확대). 본문 검색(In-file
       Matches)·화살표 탐색·엔터/클릭 열기는 손대지 않음(회귀 없음 확인). `swift test` 전체
       889개 통과(기존 883 + 신규 6), 실패 0. "종류" 칼럼·칼럼 폭 저장은 이번 범위 밖(합의된
       범위 §10 상단 참고). **수동 스모크 완료(2026-07-27, 레고 실기 확인)** — 표·정렬·이름/경로/
       크기/수정일 칼럼 정상 확인.
       — **후속(같은 날, 사용자 요청으로 범위 확장 — "방법2")**: 1단계 확인 도중 "이름찾기 인덱스
       8,000개 상한"·"pdf 등 내용 검색 안 됨"이 이어서 발견돼, Docufinder 격차 1번(표 보기)을 넘어
       **검색 자체를 통합**하는 방향으로 확장 합의:
       (a) `NoteIndexService.buildIndex` 상한 8,000→20만(1만개 단위 onChunk 진행 반영, 신규 테스트 4개)
       (b) `AppState.openFolder(at:)`/`addVault(_:)`/세션복원이 자동으로 `registerIndexFolder` 호출 —
       "등록" 버튼 없이 폴더를 열거나 볼트 연결만 해도 내용(pdf·hwp·워드·엑셀 포함) 색인 시작
       (c) `⌥⌘F`(내용 검색) 창 폐지(`IndexSearchView.swift` 삭제) — Omnisearch(`⇧⌘O`) 하나로 통합,
       In-file Matches를 실시간 스캔(pdf·오피스 제외)에서 이미 훑어둔 FTS5 색인 조회로 전환
       (d) 등록 폴더 관리(추가/재인덱싱/삭제)는 설정 > Tools 탭으로 이동
       (e) `⌘⇧8` 전역 단축키 신설(다른 앱 포커스 중에도 반응, 빠른 메모 `⌘⇧M`과 같은
       `NSEvent.addGlobalMonitorForEvents` 패턴 재사용) — 커밋 82a021d
       — **스모크 발견 버그 즉시 수정(같은 날)**: 사이드바 "홈/데스크탑/다운로드/문서" 기본 위치
       클릭이 `openFolder(at:)`를 타면서 다운로드·문서 폴더 전체(실측 16만개+)가 자동으로 내용
       색인 대상이 돼버림 — 단순 훑어보기 클릭이 의도 없이 대규모 색인 작업으로 둔갑. `openFolder
       (at:autoIndex:)` 매개변수(기본 true) 추가해 사이드바 기본 위치·경로 바 탐색·뒤로/앞으로
       히스토리는 `autoIndex: false`로 제외(File 메뉴 직접 열기·즐겨찾기·세션 복원은 그대로 자동
       등록) — 커밋 4990a74. `swift test` 전체 898개 통과, 실패 0.
       이미 등록된 다운로드·문서 폴더는 사용자 판단(그대로 두기로 결정, "그냥 하게 두자")으로
       재설치 보류 — **다운로드·문서 초기 훑기 완료 확인 후 재설치·최종 수동 스모크(통합 검색
       화면+전역 단축키) 대기 중.**
  2. **완료(2026-07-27)** 파일 우클릭 → AI 요약 한 번에(문서 타입별 핵심 요약). 사이드바
     트리·라이브러리 화면 양쪽 파일 우클릭 메뉴에 "Claude로 요약…" 추가(office/pdf/텍스트
     계열만 노출 — 이미지·미디어·모르는 형식 제외, `AppState.isSummarizable` 판정 하나 공용).
     새 UI 없이 기존 Claude 사이드 패널(`ClaudePanelView`)을 그대로 재사용 — 파일을 열지 않고도
     `ContentExtractor.body(for:kordoc:)`로 그 자리에서 본문을 뽑아 고정 프롬프트("이 문서를
     한국어로 짧게 요약해줘…")로 질의한다(`AppState.summarizeFile(at:)`). 신규 테스트 4개(순수
     판정 2·가드 동작 2), `swift test` 전체 902개 통과. **수동 스모크 대기** — 실제 pdf·hwp
     파일 우클릭 → 요약 → 패널에 응답 뜨는지, "노트로 저장" 버튼 정상 동작 확인 필요.
  3. **완료(2026-07-27)** 문서 버전 비교(같은 문서 여러 버전을 나란히, 달라진 부분 표시).
     라이브러리·사이드바에서 파일 2개를 다중 선택 후 우클릭 → "두 파일 비교…"(정확히 2개 +
     둘 다 요약 가능한 종류일 때만 노출, `AppState.comparablePair`). **나란히(2단) 대신
     이미 있는 위키 인제스트용 통합(unified) diff 컴포넌트(`LineDiff`·`WikiDiffListView`,
     추가=초록/삭제=빨강 취소선)를 재사용**했다 — 새 2단 레이아웃을 만드는 대신 "달라진 부분
     표시"라는 요구를 기존 것으로 충족(2026-07-27 설계 결정, 범위 축소). 새 시트
     `DocumentCompareView` + `AppState.requestCompare(urlA:urlB:)`(둘 다 `ContentExtractor`로
     병렬 추출 후 diff). 신규 테스트 6개, `swift test` 전체 908개 통과. **수동 스모크 대기.**
  4. **완료(2026-07-27)** 검색 결과 목록에서 다른 앱/웹으로 바로 드래그아웃(Shift+드래그=
     이동). 확인해보니 **실제로 빠져 있었다** — 라이브러리·사이드바 파일 행엔 이미 있는
     `.onDrag`(외부=Finder가 읽는 fileURL 표현, 내부=폴더로 이동 판별 신호)가 Omnisearch
     결과 행에는 없었다. 결과 행(파일명·내용검색 히트 공용) `ForEach`에 같은
     `DragPayload.makeProvider`를 재사용해 추가 — 새 드래그 로직 없이 기존 것 재사용(이미
     `DragPayloadTests`로 검증된 함수). 전용 유닛테스트는 기존 관례와 동일하게 생략(라이브러리·
     사이드바의 `.onDrag` 배선도 뷰 글루라 테스트 없음) — `swift test` 전체 908개(회귀 없음).
     **수동 스모크 대기** — 검색 결과를 Finder·다른 앱으로 실제로 끌어봐야 확인됨.
  5. **부분 완료(2026-07-27)** — 사용자 재질문("한글 말고 오피스도 안되냐?")으로 재조사.
     **MS 오피스(doc/docx/xls/xlsx)는 된다** — macOS가 자체적으로 내장 QuickLook 생성기를
     갖고 있어(Preview.app이 Word 없이도 원본 그대로 보여주는 바로 그 기능) 이미 Phase 12에서
     만든 `QuickLookPreview`(`QLPreviewView` 래퍼)를 그대로 재사용할 수 있었다. 오피스 탭
     툴바에 "원본 보기 ⇄ 글로 보기" 토글 추가(`OfficeReaderView`) — 켜면 kordoc 마크다운
     대신 `QuickLookPreview(url:)`로 원본 조판을 그대로 그린다(`AppState.
     toggleOfficeOriginalView`, 편집모드 진입 시 자동으로 꺼짐). **HWP류(hwp/hwpx/hwpml)는
     여전히 안 된다** — macOS가 이 형식 자체를 몰라 QuickLook도 못 그리고(`DocumentKind.
     nativelyRenderableOfficeExtensions`로 MS 오피스만 분리), kordoc도 SVG·HTML 렌더가
     없어(§4.1, `npx kordoc --help` 실측) 대안이 LibreOffice급 무거운 의존성뿐이라 이 부분만
     보류 유지. 신규 테스트 5개, `swift test` 전체 924개 통과. **수동 스모크 대기.**
     **후속(2026-07-29) — hwpx까지 확대 완료.** 2026-07-27 당시 "kordoc에 SVG·HTML 렌더가
     없다"고 결론 낸 것은 이 컴퓨터의 npx 캐시가 옛 kordoc 버전(3.1.1)을 계속 돌려준 탓에
     최신 기능을 놓친 오판이었다(같은 날 별도로 `kordoc@latest` 고정 — `KordocService.
     packageSpec`, 호출부 4곳). kordoc이 v3.10부터 `render` 명령(HWPX 조판 캐시 → SVG)을
     갖추고 있음을 재확인해 hwpx 원본 보기를 구현했다. 설계·계획: `docs/superpowers/specs/
     2026-07-29-hwpx-native-render-design.md`·`docs/superpowers/plans/
     2026-07-29-hwpx-native-render.md`. 신규 `KordocRenderService`(actor, kordoc render
     Process 호출 + 경로·mtime 캐시)·`HwpxRenderState`(loading/loaded/failed)·
     `HwpxRenderPreview`(WKWebView, `DropThroughWebView` 재사용). `OfficeReaderView`의
     기존 "원본 보기" 토글을 그대로 확장 — 버튼 자리·문구 불변, 확장자로 QuickLook과
     kordoc render로 내부 분기만 갈림. **`.hwp`(구버전 바이너리)·`.hwpml`은 여전히 안 된다**
     — kordoc `render` 명령 자체가 hwpx 전용임을 실측 확인(`kordoc render --help` 설명이
     "HWPX의 조판 캐시"라고 명시). 조판 캐시 없는 파일(kordoc 자체 생성/편집본)은 렌더
     실패 → "글로 보기로 전환" 버튼(크래시 없음, `--reflow` 자동 폴백은 이번 범위 밖).
     953 테스트 통과(기존 950 + 신규 3, `wrapSVG` 순수 함수). **수동 스모크 대기** — 실제
     한컴에서 저장한 진짜 hwpx 파일로 조판 캐시 기반 렌더가 되는지가 핵심 미확인 지점
     (이 컴퓨터엔 그런 샘플이 없어 개발 중엔 kordoc generate로 만든 캐시 없는 파일로만
     기술 가능성을 확인했다).
  6. **완료(2026-07-27)** — 사용자가 "토글 스위치 만들자"로 확정. 스캔 PDF(글자 레이어 없는
     이미지 PDF)에서 macOS 내장 `Vision`(`VNRecognizeTextRequest`, 한국어 지원)으로 OCR해
     검색 대상에 포함. 새 `OCRService`(순수 함수, 새 패키지 의존성 0) + 설정 토글
     `ocrScannedPDFsEnabled`(Tools 탭, **기본 OFF** — 대량 폴더 훑기를 늦출 위험 때문에
     사용자가 직접 켜야 한다). `ContentExtractor`가 먼저 보통 글자 추출을 시도하고, **정말
     텍스트가 하나도 없을 때만**(스캔본 판정) 설정이 켜져 있으면 OCR로 폴백 — 텍스트 레이어가
     있는 보통 PDF는 이 기능을 아예 타지 않아 속도에 영향 없다. 앞 30페이지까지만 OCR(대용량
     스캔집 성능 보호). `SearchIndexer.indexFolder`·`.reindex`에 플래그 배선(등록 폴더 훑기·
     파일 감시 재인덱싱 모두 반영). 신규 테스트 5개(빈 이미지 인식 안 됨 확인·실제 렌더한
     글자 인식 확인·설정 켜고 끔에 따라 스캔 PDF 색인 여부 확인·기본값 OFF 확인) — 실제
     Vision 인식이 "HELLO"·"SCAN" 문구를 정확히 읽어내는 것까지 검증됨. `swift test` 전체
     929개 통과.
  7. **완료(2026-07-27)** 이메일(.eml) 파일 검색(제목·보낸사람·받는사람·본문). 새
     `EmailExtractor`(순수 함수) — RFC 2822 헤더 파싱(접힌 헤더 합치기) + RFC 2047
     인코디드 워드 디코딩(한국어 제목이 거의 항상 이 형식, UTF-8·EUC-KR·ISO-2022-KR
     charset 지원) + 본문(단순 또는 multipart의 첫 text/plain 파트, base64·quoted-printable
     디코딩). **여는 방식(QuickLook — Mail 미리보기가 더 나음, Phase 12 유지)과 색인
     방식을 일부러 분리** — 원문 그대로 색인하면 헤더 인코딩·첨부 base64가 그대로 섞여
     검색이 오염되므로 `ContentExtractor`에 eml 전용 분기를 추가해 제목/보낸사람/받는사람/
     본문만 뽑아 색인한다. `AppState.isSummarizable`에도 eml 추가(Claude 요약·두 파일
     비교도 이메일에서 됨, 파이프라인 재사용이라 별도 코드 없음). 신규 테스트 11개.
- **상태**: 사용자가 "나열한 순서대로 진행" 결정(2026-07-27) — 2·3·4·6·7 완료, 5는 MS
  오피스만 부분 완료(HWP류는 도구 한계로 보류). 7개 항목 전부 처리 완료.
  원격(GitHub)에 v0.9.414로 릴리스 발행 완료(전역 검색 오버레이·요약·비교·드래그아웃·
  이메일 검색·오피스 원본 보기·OCR 토글 포함, `swift test` 929개 통과).


**codex(gpt-5.6-luna) 자문 후속 — 사진 속 글자 검색(이미지 OCR) 완료(2026-07-29)**

- **배경**: 레고님 요청으로 codex(gpt-5.6-luna)에게 코드베이스·PRD를 직접 읽혀 추가 기능을 자문받음(Anything/Docufinder 원본 코드도 분석시켜 설계 아이디어만 참고, 코드는 차용하지 않음— 사본은 검토 직후 삭제). 제안 6개 중 "사진 속 글자 검색"을 다음 순서로 확정(레고님 결정), "뜻으로 찾기(의미 검색)"는 맨 마지막으로 미룸.
- **구현**: 기존 스캔 PDF OCR(§3.7, Docufinder 격차 6번) 인프라를 이미지 파일(png·jpg·jpeg·heic·webp·gif)까지 확장. 설계·계획 문서: `docs/superpowers/specs/2026-07-29-image-ocr-search-design.md` · `docs/superpowers/plans/2026-07-29-image-ocr-search.md`. `AppSettings.ocrImagesEnabled`(기본 OFF, 스캔 PDF OCR과 별개 스위치) → `ContentExtractor.localBody`/`.body`에 이미지 분기(20MB 초과 사진은 이름만 색인) → `OCRService.loadCGImage(from:)` → 기존 `OCRService.recognizeText(in cgImage:)`(Vision) 재사용 → `SearchIndexer.indexFolder`/`.reindex` → `AppState` 세 호출부(전체 재색인·폴더 등록·파일감시 재인덱싱) 배선 → 설정 화면 "사진 속 글자도 읽기 (OCR)" 토글. 새 파일 없음(전부 기존 서비스 확장), 새 패키지 의존성 0.
- 4단계로 나눠 구현·커밋. 신규 테스트 11개(loadCGImage 3·설정 3·ContentExtractor 3·SearchIndexer 2). `swift test` 963개(XCTest) + 18개(Swift Testing) 통과, 회귀 0. `scripts/test_package_app.sh` 패키징 가드 통과.
- **수동 스모크 대기** — 설정에서 켜고 실제 사진 파일로 검색되는지 확인 필요.
---
## 부록 A. Claude Code 시작 프롬프트 (예시)

> "이 저장소는 CmdMD(Swift/SwiftUI, SPM) 포크다. 먼저 `swift build`·`swift test`로 빌드·테스트를 확인하고, `Sources/`를 읽어 파일 열기/탭/프리뷰 디스패치 위치와 프리뷰가 WebView 기반인지 보고해라. 그다음 PRD 티어 1의 Phase 1(이미지)→2(PDF)→3(kordoc 읽기) 순으로 진행한다. kordoc·claude는 `Process`로 호출하는 외부 CLI다. 각 Phase는 기존 테스트를 깨지 않는 선에서, 마치면 변경 요약을 보고해라."