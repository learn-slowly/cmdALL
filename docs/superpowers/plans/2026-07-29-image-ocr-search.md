# 사진 속 글자 검색 (이미지 OCR) — 구현 계획

- 날짜: 2026-07-29
- 설계 문서: `docs/superpowers/specs/2026-07-29-image-ocr-search-design.md`
- 상태: 승인됨 — 구현 착수
- 사용자 결정(2026-07-29, 채팅): 크기 상한 20MB·PDF OCR과 별개 토글·이 계획대로 진행, 전부 승인("고고")

---

## 쉬운 말 요약 (레고용)

- **이번에 만드는 것**: 지금 스캔 PDF만 읽어주는 글자 인식(OCR)을 사진 파일(jpg·png·heic·webp·gif)에도 붙인다. 설정 화면에 새 스위치 하나 추가(기본 꺼짐). 켜면 사진 속 글자로도 검색된다.
- **이번엔 안 하는 것**: 사진 화면에 글자를 보여주는 것, 사진 자동 축소, 두 OCR 스위치 통합.
- **순서**: 태스크 1~4를 하나씩 만들고, 태스크마다 `swift test` 통과 확인 후 커밋. 마지막에 전체 재확인.

---

**Goal:** 폴더 등록 내용 색인이 사진 파일도 Vision OCR로 읽어 검색 대상에 포함하게 한다(설정 기본 OFF). 기존 스캔 PDF OCR·다른 호출부(요약·RAG·위키 인제스트)는 손대지 않는다.

**Architecture:** 기존 `OCRService`(Vision 래퍼)에 이미지 로딩 헬퍼를 더하고, `ContentExtractor.localBody`/`.body`에 새 `ocrImages` 매개변수(기본 `false`)로 이미지 분기를 추가한다. `SearchIndexer`가 이 매개변수를 그대로 통과시키고, `AppState`의 폴더 색인 호출 3곳이 `settings.ocrImagesEnabled`를 넘긴다. 새 파일 없음 — 전부 기존 함수 확장.

**Tech Stack:** Swift 5.9+ / SwiftUI, Vision, XCTest. 새 패키지 의존성 0.

## Global Constraints

- 새 패키지 의존성 0.
- macOS 14+ / Swift 5.9+.
- 코드 주석·커밋 메시지·UI 문구는 **한국어**.
- 글에서 '박다/박는다/박았다' 표현은 쓰지 않는다.
- **기존 호출부 회귀 없음** — `ocrScannedPDFs`/`ocrImages` 둘 다 기본값 `false`이므로 매개변수를 안 주는 기존 호출(`CleanupService`·`RagPassageExtractor`·`WikiIngestService`)은 지금과 100% 동일하게 동작해야 한다.
- 원본 파일 불변(읽기 전용 — OCR은 색인용 텍스트만 만든다).
- 각 태스크는 `swift test` 전체 통과로 끝난다. **기준선 971개**(XCTest 953 + Swift Testing 18, 2026-07-29 실측). 기존 테스트를 깨뜨리지 않는다.
- 테스트는 XCTest, `@testable import CmdMD`.

---

## 파일 구조

**새로 만드는 파일 없음.**

**손대는 기존 파일**

| 파일 | 변경 |
|---|---|
| `Sources/Services/OCRService.swift` | `loadCGImage(from url:)` 헬퍼 추가 |
| `Sources/Services/ContentExtractor.swift` | `maxOCRImageBytes` 상수 + `localBody`/`body`에 `ocrImages` 매개변수·이미지 분기 |
| `Sources/Services/SearchIndexer.swift` | `indexFolder`/`reindex`에 `ocrImages` 매개변수 |
| `Sources/App/AppState.swift` | 3개 호출부(1908·1919·1970행 부근)에 `ocrImages: settings.ocrImagesEnabled` 추가 |
| `Sources/Models/Settings.swift` | `ocrImagesEnabled: Bool = false` 필드 + Codable 디코드 |
| `Sources/Views/SettingsView.swift` | 토글 1개(820행 부근) + footer 문구 갱신 |
| `Tests/CmdMDTests/OCRServiceTests.swift` | `loadCGImage` 테스트 추가 |
| `Tests/CmdMDTests/ContentExtractorTests.swift` 또는 `ContentExtractorTextTests.swift` | 이미지 OCR 켜짐/꺼짐/크기상한 테스트 추가 |
| `Tests/CmdMDTests/SettingsAndEditorTests.swift` | `ocrImagesEnabled` 기본값·라운드트립 테스트 추가 |

---

## Task 1: `OCRService.loadCGImage(from:)` + 이미지 인식 테스트

**Files:**
- Modify: `Sources/Services/OCRService.swift`
- Test: `Tests/CmdMDTests/OCRServiceTests.swift`

**Interfaces:**
- Produces: `static func loadCGImage(from url: URL) -> CGImage?` — `NSImage(contentsOf:)` → `cgImage(forProposedRect:context:hints:)`. 파일 없음/디코딩 실패 시 `nil`(크래시 없음).

- [ ] RED: 실제로 렌더한 작은 PNG(텍스트 "HELLO" 그린 것, 기존 `testRecognizeTextFindsRenderedWord` 픽스처 패턴 재사용)로 `loadCGImage`가 유효한 `CGImage`를 반환하는지, 없는 파일 경로는 `nil`인지, 손상된(빈) 데이터는 `nil`인지 테스트 작성
- [ ] GREEN: 함수 구현
- [ ] `swift test --filter OCRServiceTests` 통과 확인 → 전체 회귀 → 커밋(`기능: OCRService.loadCGImage — 이미지 OCR 1단계`)

---

## Task 2: `AppSettings.ocrImagesEnabled` 설정

**Files:**
- Modify: `Sources/Models/Settings.swift`
- Test: `Tests/CmdMDTests/SettingsAndEditorTests.swift`

**Interfaces:**
- Produces: `var ocrImagesEnabled: Bool = false`(저장 프로퍼티), Codable `decodeIfPresent(Bool.self, forKey: .ocrImagesEnabled) ?? d.ocrImagesEnabled`(기존 `ocrScannedPDFsEnabled` 패턴 그대로)

- [ ] RED: 기본값이 `false`인지, `testSettingsRoundTrip`류에 이 필드가 라운드트립되는지, 빈 JSON에서 디코드해도 기본값으로 채워지는지 테스트 추가
- [ ] GREEN: 필드 + CodingKeys + init(from:) 디코드 추가(기존 `ocrScannedPDFsEnabled` 옆)
- [ ] `swift test --filter SettingsAndEditorTests` 통과 확인 → 전체 회귀 → 커밋(`기능: ocrImagesEnabled 설정 — 이미지 OCR 2단계`)

---

## Task 3: `ContentExtractor` 이미지 OCR 분기

**Files:**
- Modify: `Sources/Services/ContentExtractor.swift`
- Test: `Tests/CmdMDTests/ContentExtractorTests.swift`(또는 `ContentExtractorTextTests.swift`)

**Interfaces:**
- Produces: `static let maxOCRImageBytes = 20 * 1024 * 1024`(20MB)
- Modifies: `localBody(for url: URL, ocrScannedPDFs: Bool = false, ocrImages: Bool = false) -> String?` — 이미지 분기 추가(PDF 분기 아래, `DocumentKind.imageExtensions.contains(ext)` 체크 → `ocrImages` 꺼지면 `nil` → 크기 초과면 `nil` → `OCRService.loadCGImage` 실패 시 `nil` → `OCRService.recognizeText(in:)`)
- Modifies: `body(for url: URL, kordoc: KordocService, ocrScannedPDFs: Bool = false, ocrImages: Bool = false) async -> String?` — `localBody` 위임 호출에 `ocrImages` 전달

- [ ] RED: (a) `ocrImages: false`(기본)면 이미지가 여전히 `nil` 반환(기존 `testLocalBodyUnsupportedReturnsNil` 회귀 확인) (b) `ocrImages: true` + 실제 글자를 렌더한 PNG면 인식된 텍스트 반환 (c) `ocrImages: true`지만 20MB 초과 파일이면 `nil`(더미 큰 파일로 크기만 확인, 실제 20MB 이미지 만들 필요 없이 `resourceValues` 우회 어려우면 상한 자체를 테스트 가능한 작은 값으로 임시 낮춰 검증하는 대신 실측 파일 크기로 경계 확인) 테스트 작성
- [ ] GREEN: 이미지 분기 구현
- [ ] `swift test --filter ContentExtractorTests` 통과 확인 → 전체 회귀 → 커밋(`기능: ContentExtractor 이미지 OCR 분기 — 이미지 OCR 3단계`)

---

## Task 4: `SearchIndexer`·`AppState`·`SettingsView` 배선

**Files:**
- Modify: `Sources/Services/SearchIndexer.swift`
- Modify: `Sources/App/AppState.swift`
- Modify: `Sources/Views/SettingsView.swift`

**Interfaces:**
- Modifies: `SearchIndexer.indexFolder(_:ocrScannedPDFs:ocrImages:progress:)`·`.reindex(path:ocrScannedPDFs:ocrImages:)` — `ContentExtractor.body` 호출에 `ocrImages` 전달
- Modifies: `AppState.swift` 세 호출부(대략 1908·1919·1970행)에 `ocrImages: settings.ocrImagesEnabled` 추가
- Modifies: `SettingsView.swift` — PDF OCR 토글 아래 `Toggle("사진 속 글자도 읽기 (OCR)", isOn: $state.settings.ocrImagesEnabled)` + footer 문구에 사진 OCR 설명 추가

- [ ] RED: `SearchIndexerTests`에 `ocrImages: true`로 폴더를 색인하면 이미지 파일 안 글자가 검색되는지(작은 렌더 PNG 픽스처), `ocrImages: false`(기본)면 여전히 안 되는지 테스트 추가
- [ ] GREEN: 세 파일 배선
- [ ] `swift test --filter SearchIndexerTests` 통과 확인 → 전체 회귀 → 커밋(`기능: 이미지 OCR 색인·설정 화면 배선 — 이미지 OCR 4단계`)

---

## 마무리

- [ ] 전체 `swift test` 통과(기준선 971개 + 신규분, 실패 0) 확인
- [ ] `swift build` 경고 0 확인
- [ ] `scripts/test_package_app.sh`로 패키징 가드 통과 확인(기존 관례)
- [ ] `CmdMD-fork_prd.md`에 완료 기록 추가(§3.7 내용 검색 또는 §10에 이미지 OCR 항목 신설)
- [ ] `CLAUDE.md`에 완료 기록 추가
- [ ] 레고님 수동 스모크 대기 안내(실제 사진 파일로 설정 켜고 검색 확인 필요)
