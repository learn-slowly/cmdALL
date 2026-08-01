# 학습도우미(Study Helper) — 구현 계획

- 날짜: 2026-07-31
- 설계 문서: `docs/superpowers/specs/2026-07-31-study-helper-design.md`
- 근거: ralplan 최종 계획(`.gjc/_session-019fb747-1154-7000-bcf4-16fdfeab1bad/plans/ralplan/2026-07-31-study-helper/pending-approval.md`, stage_n 7) — 레고 실행 승인 완료
- 상태: **S0·S1·S3·S2 전부 완료(S2는 2026-08-01)**. S0(정리 카드/문제 뽑기 프리셋) → S1(코어+카드+퀴즈+저장) → S3(대화하며 공부하기) → S2(오늘 복습·채점). `swift test` 1,334개 전량 통과.
- 사용자 결정: §Intent Reconciliation 참고(설계 문서) — S1 다음은 S3(대화) 먼저, S2(복습)는 그 다음 / 대화 크래시 대비 임시 저장 기본 ON. **S2 착수 게이트 우회(2026-08-01, 레고 확정)**: 원래 §게이트 매트릭스는 S2 착수 전제로 "S1 완료 + 산출 노트 ≥10개 + 2주 실사용"을 못박아뒀으나, S1이 완성된 바로 그날 레고가 "그 규칙 무시하고 지금 바로 시작한다 — 대화기능 때처럼"이라고 명시적으로 확인해 노트 축적·실사용 기간 조건 없이 착수함(대화(S3) 착수 때도 같은 방식으로 게이트를 건너뛴 전례 있음).

---

## 게이트 매트릭스 (S0 필수, 예외 없음)

| 슬라이스 | 착수 전제(증거) | 전제가 아닌 것 | 상태 |
|---|---|---|---|
| **S0** 프리셋 실험 | 없음 | — | **완료(2026-07-31)** |
| **S1** 코어+카드+퀴즈 | **S0 실사용 ≥3회 + "쓸 만하다" 판정 (필수, 우회 없음)** | S2·S3 무관 | **완료(2026-08-01, v0.9.427)** |
| **S3** 대화 | **S1 완료** | **S2와 무관 — S2 없이 착수 가능** | **완료(2026-08-01, v0.9.428)** |
| **S2** 복습 | **S1 완료** + 산출 노트 ≥10개 + 2주 실사용 | **S3와 무관** | **완료(2026-08-01) — 노트≥10개·2주 실사용 조건은 레고가 명시적으로 우회** |
| S2 후속(통계 등) | S2 실사용 증거 | — | 범위 밖 |

- **S0 → S1은 필수 경로다.** S0 판정이 부정적이면 문제 재정의로 돌아간다.
- S2·S3는 서로의 전제가 아니며, **순서는 레고가 S3 우선으로 확정**했다(설계 문서 §Intent Reconciliation).

---

## In scope / Out of scope

**In scope**: S0 프리셋 2개 · S1 코어+카드+퀴즈+저장(제안→확인) · **S3 대화(+크래시 임시 초안)** · S2 복습 · 설정(학습 폴더, 노트 저장 위치, `chatContextCap`(권장 4,000~40,000·기본 12,000), 청크 예산, 문항 수, 하루 상한, 턴 유지 개수, `studyChatAISummary`(기본 OFF), **`studyChatCrashRecovery`(기본 ON)**).

**Out of scope — "이번에 하지 않을 것"** (13항)
1. OS 알림 센터 알림. 2. 학습 통계·그래프·스트릭. 3. 여러 기기 동기화·서버. 4. 임베딩/의미 검색. 5. 그림·표·수식 이미지째 카드 삽입. 6. 음성 학습. 7. 폴더·과목 단위 일괄 생성. 8. 교재 원본 수정·하이라이트 기록. 9. CLI 세션 재개 플래그 채택. **10. 대화의 자동 *영구* 저장 — 앱이 사용자 동의 없이 대화를 볼트 정식 노트로 남기는 것. (※ 설계 문서 §4.7의 크래시 대비 임시 초안은 여기 해당하지 않는다: 볼트 밖·정상 종료 시 삭제·복구는 사용자 확인 후·설정 OFF 가능.)** 11. 다국어 UI. 12. 문항 난이도 추정·IRT. 13. 등록 학습 폴더 밖 노트 자동 발견.

추가 명시: **초안 파일의 여러 세션 보관·이력 관리·수동 내보내기는 하지 않는다**(항상 최신 1개만).

**S0 스코프 안 (이번에 실제로 한 일)**:
- 기존 AI 패널(`Sources/Views/ClaudePanelView.swift`)에 "정리 카드 만들기"·"문제 뽑기" 버튼 2개 추가.
- 버튼은 `AppState.fillStudyCardPrompt()`/`fillStudyQuizPrompt()`(신규, `Sources/App/AppState+Claude.swift`)를 호출해 프롬프트 입력창(`claudePrompt`)만 채운다. 전송은 기존 "질문 (⌘↩)" 버튼을 사용자가 직접 눌러야 실행된다.
- 새 파이프라인·파서·서비스 파일 생성 없음 — 기존 `askClaude()`/`aiRouter.askStream` 경로 그대로 재사용(`summarizeFile()`의 "프롬프트만 채우기" 패턴을 그대로 따름).

**S0 스코프 밖 (이번에 하지 않은 것 — S1 이후로 유보)**:
- `StudySourceLoader`/`StudyChunker`/`StudyPromptBuilder`/`ChatContextAssembler`/`StudyOutputParser`/`StudyNoteWriter`/`StudyNoteParser`/`ReviewScheduler`/`StudyIndex`/`StudyService`/`StudyChatService`/`StudyChatDraftStore` 등 S1~S3 전용 신규 서비스 파일 전부.
- 위치 태그(`[[p12]]`) 자동 파싱·인용 검증(O4)·노트 저장(`StudyNoteWriter`)은 아직 없다. S0 프롬프트는 카드/문제 "형식"만 요청할 뿐, 그 출력을 구조화해 파싱·저장하는 파이프라인은 S1에서 만든다.

---

## File-level changes

### S0(완료)

| 파일 | 변경 |
|---|---|
| `Sources/Views/ClaudePanelView.swift` | 프롬프트 입력창 위에 "정리 카드 만들기"·"문제 뽑기" 버튼 2개(HStack) 추가. `claudeBusy`일 때 비활성화. 기존 레이아웃·다른 버튼(질문/본문에 삽입/노트로 저장/복사) 그대로. |
| `Sources/App/AppState+Claude.swift` | `fillStudyCardPrompt()`·`fillStudyQuizPrompt()` 2개 함수 추가(신규 MARK 섹션). `claudePrompt`만 대입, 전송·상태 변경 없음. |

### S1~S3(예정 — 레고 실사용 판정 후)

**새로 만들 파일**

| 파일 | 책임 |
|---|---|
| `Sources/Models/StudyLocator.swift` | `StudyLocator`·`StudySegment`·`StudyChunk` |
| `Sources/Models/StudyItem.swift` | `StudyCard`·`StudyQuestion`·`StudyItemKind`·`StudyReviewState` |
| `Sources/Models/StudyScope.swift` | 학습 범위 |
| `Sources/Models/StudyChatDraft.swift` | 초안 `Codable` 모델(설계 문서 §4.7.2) |
| `Sources/Services/StudySourceLoader.swift` | 종류별 세그먼트 생성 |
| `Sources/Services/StudyChunker.swift` | 세그먼트 → 청크 |
| `Sources/Services/StudyPromptBuilder.swift` | 카드/퀴즈/대화/요약 프롬프트 |
| `Sources/Services/ChatContextAssembler.swift` | §4.2 전부(배분 공식·트리밍·`.assembled`/`.noSend`) |
| `Sources/Services/StudyChatDraftStore.swift` | §4.7 전부 — 디바운스 판정·원자적 쓰기·만료·삭제·복구 후보 로드(순수 판정 함수 분리) |
| `Sources/Services/StudyOutputParser.swift` | 출력 → 항목 배열 |
| `Sources/Services/StudyNoteWriter.swift` | 항목 → 마크다운 · `item_uid` 발급 |
| `Sources/Services/StudyNoteParser.swift` | 노트 → frontmatter + 앵커 항목 |
| `Sources/Services/ReviewScheduler.swift` | SM-2 라이트 |
| `Sources/Services/StudyIndex.swift` | `studyindex.sqlite` + 재빌드 |
| `Sources/Services/StudyService.swift` | 오케스트레이션 actor |
| `Sources/Services/StudyChatService.swift` | S3 세션·스트림 취소 소유 + Store에 저장 신호 전달 |
| `Sources/Views/StudyHelperView.swift` · `StudyReviewView.swift` · `StudyChatView.swift` | UI(대화 화면 진입 시 복구 시트 포함) |
| `Tests/CmdMDTests/Study*Tests.swift` | §Verification Plan |

**손댈 기존 파일(최소 배선)**: `AppState.swift`(서비스 조립·정상 종료 훅에서 초안 삭제) · `AppState+Study.swift`(신규) · `CmdMDApp.swift`(메뉴/단축키·종료 훅) · `CommandPaletteView.swift` · `Settings.swift`(신규 키 + `chatContextCap` 0 이하 거부 + `studyChatCrashRecovery`) · `SettingsView.swift`(학습 섹션 + 초안 도움말 한 줄) · `docs/todolist.md` · `CmdMD-fork_prd.md`(§3.15).

---

## Sequencing and dependencies (순서 확정 반영)

- **S0 (0.5~1일) — 필수 관문.** 실사용 3회 판정 전에는 S1 코드를 시작하지 않는다. **→ 코드 완료, 레고 실사용 판정 대기.**
- **S1 (4~6일)** — 모델 → `StudySourceLoader` → `StudyChunker` → `StudyPromptBuilder` → `StudyOutputParser` → `StudyService`(가짜 AI) → `StudyNoteWriter` → UI → 수동 스모크.
- **S3 (5~7일) — S1 다음은 여기(레고 확정).** 세션 모델 → `ChatContextAssembler`(순수, 테스트 선행) → `StudyChatService`(스트림·취소) → UI → 옵트인 "노트로 남기기" → `StudyChatDraftStore`(+0.5~1일: 디바운스·원자 쓰기·삭제 훅·복구 시트) → (옵션) AI 요약.
- **S2 (3~4일) — S3 다음.** `ReviewScheduler` → `StudyNoteParser` → `StudyIndex` → 오늘 복습 화면 → 채점 → 배지.
- 총량은 이전과 사실상 동일(S3에 초안 저장분 +0.5~1일). 각 슬라이스 종료 = `swift test` 전량 통과 + 커밋 + worklog 기록 + todolist 정리.

---

## Acceptance criteria

**S0**
1. AI 패널에 "요약 카드"·"문제 뽑기" 버튼이 있고, 누르면 프롬프트가 채워진다. — **충족**(레고 확정 문구는 "정리 카드 만들기"·"문제 뽑기"). 버튼 클릭 → `claudePrompt`가 카드/퀴즈 형식 프롬프트로 채워짐, 전송은 별도.
2. 기존 패널 동작에 회귀가 없다. — **충족**(`AppClaudeTests` 33개 포함 전체 1,070개 통과, 질문/삽입/저장/복사 로직 미변경).

**S1**
3. 여러 종류 파일에서 세그먼트가 생성되고, 총 본문이 공백이면 **AI 호출 0회**로 안내만 낸다.
4. 카드 항목은 제목·불릿 1~3개(4번째부터 폐기)·근거 1개 + §O3 상한.
5. 문제 항목은 제목·`type`·`Q:`·(mcq면 보기 3~5)·`A:`·`해설:`·근거 1개 + **문항별 `loc`**.
6. 저장은 미리보기 후 사용자가 눌러야만 파일이 생긴다. 취소 시 디스크 변화 0.
7. 생성 노트는 필수 frontmatter 키 + 항목 수만큼의 정규 앵커를 갖는다.
8. 교재 원본의 mtime·크기·바이트가 실행 전후 동일하다.
9. 실행 전 "보낼 분량 약 N자 · 조각 C개"(결정적), 소요 시간은 완료 후 실측만.
10. AI 실패 시 한국어 안내 + 크래시 없음.
22. 청크 밖 `[[loc]]` 인용은 `.unknown` 강등 + `invalidCitations` 증가.
23. 유효 항목 0건이면 정확히 1회 재요청, 두 번째도 0건이면 그 청크만 실패.
24. 청크 C개 중 k개 성공 시 결과 표시 + "C개 중 k개 성공".

**S3 (S1 다음 착수)**
17. 3턴 이상 대화에서 앞 턴 내용이 전송 컨텍스트에 포함된다.
18. `.assembled(s)`면 `s`의 **전체 길이(프레이밍 포함)가 `cap` 이하**. 밀려난 턴은 결정적 접기로 대체되고 같은 입력이면 결과가 항상 같다.
31. 경계 케이스 (a) 최악 입력 (b) 프리앰블 ≥ cap 즉시 no-send (c) 아주 작은 cap에서 4단계 1회씩 후 `.noSend(.cannotFitAfterTrim)`(루프 없음) (d) 질문 구획 0 → no-send (e) 구획 합 = contentBudget (f) 4단계 no-op 통과.
19. "중단"이 진행 중 호출을 끊는다(취소 후 busy 해제, 부분 텍스트 유지, `(중단됨)`).
20. (개정) **정상 종료 경로**(대화 닫기·앱 정상 종료·"노트로 남기기" 완료)에서는 **볼트 신규 파일 0개이고 초안 파일도 0개**다. **비정상 종료(크래시·강제 종료) 때에만** 초안 파일 1개가 다음 실행까지 남는다.
21. "노트로 남기기"는 **화면의 원본 턴 전문**을 저장한다.
29. `studyChatAISummary` OFF면 요약용 AI 호출 0회. ON이고 실패하면 에러 없이 결정적 접기로 폴백.
30. 대화 턴은 콜별 타임아웃 미지정·자동 재시도 없음.
32. (신설) 초안 파일이 남은 상태로 재실행하면 **대화 화면 진입 시** 복구 시트가 뜬다. **[이어서 하기]** → 핀 발췌·턴이 그대로 복원되고(원본 경로가 없으면 대화만 복원 + 안내), 초안은 유지되다가 이후 정상 종료 시 삭제된다. **[지우기]** → 즉시 삭제되고 같은 프롬프트가 다시 뜨지 않는다. **자동 복구는 발생하지 않는다.**
33. (신설) `studyChatCrashRecovery`가 OFF면 초안 **쓰기 0회**이고, 기존 초안 파일이 있으면 설정 변경/대화 진입 시점에 삭제된다.
34. (신설) `schemaVersion` 불일치·손상 JSON·`updatedAt` 14일 초과·턴 0개 초안은 **복구 시트 없이 조용히 삭제**되고 크래시하지 않는다.
35. (신설) 저장은 **원자적 교체**라 쓰기 도중 중단돼도 이전 초안이 손상되지 않는다. 스트리밍 중에는 **5초 미만 간격의 추가 쓰기가 발생하지 않고**(가짜 클록으로 검증), 내용이 바뀌지 않았으면 쓰지 않는다.

**S2 (S3 다음 착수)**
11. `ReviewScheduler`가 §3.9대로 동작(경계값 포함).
12. 등록 폴더 안에서 노트를 옮겨도 재빌드 후 `item_uid` 기준으로 살아 있다.
13. `studyindex.sqlite`를 삭제해도 크래시 없이 재빌드하고 개수가 일치한다.
14. "오늘 복습" 개수 = due ≤ 오늘 항목 수(상한 적용 후).
15. 채점 시 해당 앵커 줄만 갱신, 다른 줄·서식 불변(라인 diff), 백업 1부 생성.
16. 교재 원본 여전히 불변.
25. uid 중복 시 mtime 최신 승자, 동일하면 정규화 경로 오름차순 승자. 반복 재빌드 결과 동일, 두 파일 모두 미수정.
26. 깨진 앵커 줄은 무시되고 나머지 항목은 정상 처리.
27. 채점 직전 외부 변경 시 쓰기 포기 + 안내.
28. 등록 폴더 밖 노트는 인덱스 미포함.

---

## Verification

- 게이트: `swift test` — **기준선 1,068개** + 신규. 슬라이스 시작·종료 시 실행.
- 패키징 변경이 없으면 `scripts/test_package_app.sh` 불필요.
- 수동 스모크(레고): 자격증 PDF 1권 · 회사 HWP 1건 · 마크다운 노트 1건 · 글자 있는 사진 1장(OCR ON) 각각 카드·퀴즈 1회 + **대화 중 강제 종료 → 재실행 복구 1회**.

**S0 실측(2026-07-31)**:
- `swift build` — 빌드 성공(경고 없음, 신규 코드 관련).
- `swift test` — 1,070개 테스트 전량 통과(신규 테스트 파일 없음, 기존 `AppClaudeTests` 33개 포함 회귀 없음 확인). 최초 1회 실행에서 `AppIndexSearchTests.testAutoSchemaMigrationReindexShowsProgress` 1건이 실패했으나 이번 변경과 무관한 파일이며 단독/재실행 모두 통과 — 기존에 존재하던 타이밍성 플레이키 테스트로 판단.
- 버튼 2개(`정리 카드 만들기`·`문제 뽑기`)가 AI 패널에 노출되고, 클릭 시 `AppState.claudePrompt`가 카드/퀴즈 형식 프리셋 문구로 채워짐을 코드로 확인(`fillStudyCardPrompt()`/`fillStudyQuizPrompt()` → `claudePrompt` 대입, 전송 없음).

## Verification Plan (확장 테스트 계획 — S1 이후)

**Unit (순수 함수)**
- `StudyChunker`: 헤딩 경계 · 페이지 경계 보존 · 태그·구분자 포함 예산 · 강제 분할 + locator 승계 · 빈 입력 · `coveredLocators`.
- `StudySourceLoader`(분해 가능 부분): 헤딩→줄 번호 · PDF 인덱스+1 · 빈 페이지 스킵 · office/이미지 `.unknown`.
- `StudyOutputParser`: `###` 블록만 추출 · 필수 필드 누락 폐기 · 불릿 4번째 폐기 · §O3 상한 · 무효 태그 강등 · 발췌 미검증 카운트 · 중복 제목 폐기 · N 초과 폐기.
- `ChatContextAssembler`: 사후조건 `count ≤ cap` · 기본값 검산 · `reserve` 반올림 경계 · `P > reserve` 축소 · `P ≥ cap` no-send · `question == 0` no-send · floor 잔여 핀 가산 · 핀 바닥값 · 작은 cap에서 4단계 1회씩 후 no-send · no-op 통과 · 100자 블록 + `…(생략)` 재계산 · 극단값(cap 1·2·959·960·961) 무크래시.
- **`StudyChatDraftStore`(신설)**: 인코딩 라운드트립(턴 순서·핀 발췌 보존) · **만료 판정**(13일 59분 = 유효, 14일 초과 = 폐기) · `schemaVersion` 불일치 판정 · 손상 JSON 처리 · 턴 0개 폐기 · **디바운스 게이트 순수 판정**(마지막 저장 시각 + 내용 해시 변화 여부 → 저장 여부) · 삭제 멱등성.
- `StudyNoteWriter` / `StudyNoteParser` / `ReviewScheduler` / 대화 접기 / `Settings`(신규 키 하위호환 + `chatContextCap` 0 이하 거부 + `studyChatCrashRecovery` 기본 ON).

**Integration (가짜 AI·임시 디렉터리)**
- `StudyService` + `FakeClaudeAsking`: 본문 0자 → 호출 0회 · 형식 붕괴 → 1회 재요청 · 부분 성공 집계 · 300초 타임아웃 1회 재시도 · 에러 → 한국어 안내.
- `StudyChatService` + 가짜 스트림: 호출 1회·재시도 없음 · 취소 시 스트림 종료 · AI 요약 OFF면 호출 0회 · 요약 실패 폴백 · `.noSend`일 때 AI 호출 0회.
- **초안 수명주기(임시 `appDir` 주입)**: 턴 종료 시 파일 생성 · 5초 미만 재저장 억제 · **정상 종료 훅에서 삭제** · "노트로 남기기" 후 삭제 · 새 세션 시작 시 삭제 · 복구 [이어서 하기]/[지우기] 각각의 파일 상태 · `studyChatCrashRecovery` OFF 전환 시 즉시 삭제 · **원자적 교체 검증(쓰기 중단 시뮬레이션 후 이전 초안 무손상)**.
- `AppState(dataDirectory: TempDataDirectory.make())` 격리 저장: 취소 시 0개, 저장 시 1개.
- `StudyIndex`: 삽입·due 필터·재빌드·DB 삭제 복구·손상 DB·중복 uid(동점 포함)·폴더 밖 제외.
- 채점 갱신: 앵커 줄만 변경 · 외부 변경 시 포기 · 백업 생성.
- 원본 불변 회귀 / `searchindex.sqlite` 불변 회귀.

**E2E / 수동**
- 실제 `claude`로 PDF 1챕터 → 카드·퀴즈 → `[[p12]]` 점프 → 저장 → due 세팅 → 복습 → 채점.
- 스캔 PDF(OCR ON) 페이지 폴백 / kordoc 실패 안내 / codex 전환 1회.
- 대화 20턴 → 접기·트리밍·중단·노트로 남기기.
- `chatContextCap`을 아주 작게 → 전송되지 않고 안내(부분 전송 없음).
- **대화 중 앱 강제 종료(Force Quit) → 재실행 → 대화 화면 진입 시 복구 시트 → 이어서 하기 → 내용 일치 확인 → 정상 종료 후 초안 파일이 사라졌는지 확인.**

**Observability**
- 실행 전 "보낼 분량 N자 · 조각 C개", 실행 후 "N초 걸렸어요".
- 결과 헤더 "조각 C개 중 k개 성공 · 유효 인용 k/n".
- 트리밍 발동 시 "이전 대화 일부를 줄여서 보냈어요".
- `.noSend` 시 "보낼 수 있는 자리가 없습니다. 설정에서 한 번에 보낼 글자 수를 늘려 주세요".
- **초안 복구 시 "이전에 하다 만 대화를 이어왔어요" 1줄 · 초안 쓰기 실패는 사용자에게 알리지 않고 로그만 · 만료/손상 초안 삭제도 로그만.**
- 재빌드 시 "학습 목록을 다시 훑었습니다: N건(제외 M건)".

---

## Escalation / Risk Gate

- 게이트는 §게이트 매트릭스(S0 필수, 이후 S1 → S3 → S2).
- 에스컬레이션 트리거: (a) 마크다운 문법 파싱 3회 이상 붕괴 → JSON 강제 출력 전환, (b) 예산 내 카드 품질 미달 → 챕터 입도 재정의, (c) 페이지 단위 OCR 폴백이 느리면 스캔 PDF를 S1 범위에서 제외, **(d) 초안 저장이 체감 지연을 만들면 디바운스 간격을 5초 → 15초로 늘리고 턴 종료 저장만 유지**.

---

## Handoff

- **S0 완료(2026-07-31).** 다음 단계는 **레고의 실사용 3회 + "쓸 만하다" 판정**이다. 이 판정 없이는 S1 착수 금지(우회 없음).
- 판정이 긍정적이면: S1(모델 → `StudySourceLoader` → … → UI) 착수 전 §Follow-ups(설계 문서)의 코드 조사 3건(스캔 PDF OCR 폴백 속도, 학습 노트 기본 저장 위치, 앱 정상 종료 훅 실존 확인)을 먼저 수행한다.
- 판정이 부정적이면: 문제 재정의로 돌아간다(S1 이후 착수하지 않음).
