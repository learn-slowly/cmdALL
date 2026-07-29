# 사진 속 글자 검색 (이미지 OCR) — 설계

- 날짜: 2026-07-29
- 상태: 설계 승인 대기
- 상위 문서: `CmdMD-fork_prd.md` §10(Docufinder 대비 기능 격차 논의), 오늘 대화 결정(codex(gpt-5.6-luna)에게 추가 기능 자문 → "사진 OCR"을 다음 순서로 확정, "뜻으로 찾기"는 맨 뒤로 미룸)
- 기준선: `swift build` 성공, `swift test` 971개 전부 통과(XCTest 953 + Swift Testing 18, 실패 0, 2026-07-29 실측)

---

## 쉬운 말 요약 (레고용)

- **이번에 할 일**: 지금 "스캔한 PDF"만 글자를 읽어주는 기능(설정 켜면 사진처럼 찍힌 PDF도 검색됨)을, 진짜 사진 파일(영수증·스크린샷·회의록 사진 등, jpg·png·heic·webp·gif)에도 그대로 붙인다. 설정에서 따로 켜고 끌 수 있고, 기본은 꺼짐(사진 많은 폴더를 훑을 때 느려질 수 있어서).
- **이번엔 안 할 일**: 사진을 열었을 때 화면에 인식된 글자를 보여주거나 복사하는 기능(이번엔 "찾기"만, "보여주기"는 아님) — 이미지 리더 화면은 그대로. 사진을 자동으로 줄여서 더 빠르게 만드는 것(필요하면 나중에). "스캔 PDF OCR"과 "사진 OCR"을 하나의 스위치로 합치는 것(따로 켜고 끄게 둠).
- **순서**: 이 설계 문서 확인 → 실행 계획서(태스크 목록) 작성 → 승인 → 태스크 하나씩 구현+테스트 → 커밋 → 마지막 전체 확인.

---

## 1. 목적

지금 이미지 파일(`png jpg jpeg heic webp gif`)은 내용 검색 대상에서 **완전히 빠져 있다** — 파일명으로만 찾아진다. 레고님 실제 자료(영수증 사진, 화이트보드 사진, 스크린샷 등)에 자주 등장하는 형식인데, 그 안의 글자로는 검색이 안 된다는 뜻이다. 이미 스캔 PDF에는 같은 문제를 macOS 내장 Vision으로 풀어둔 전례(`OCRService`, Docufinder 격차 6번)가 있으니, 그 인프라를 이미지 파일까지 넓히는 확장 작업이다.

---

## 2. 실측으로 확인한 것 (코드로 직접 대조, 추정 아님)

| 항목 | 실측 | 위치 |
|---|---|---|
| 이미지 확장자 목록 | `["png", "jpg", "jpeg", "heic", "webp", "gif"]` | `DocumentKind.imageExtensions` |
| 이미지 본문 추출 | 없음 — `localBody`가 이미지 분기 자체가 없어 항상 `nil` 반환(텍스트 판정에 안 걸림) | `ContentExtractor.localBody`, 테스트 `testLocalBodyUnsupportedReturnsNil`("이미지: 본문 없음") |
| OCR 엔진 | 이미 있음 — `OCRService.recognizeText(in cgImage:languages:)`(Vision, 새 패키지 의존성 0) | `Sources/Services/OCRService.swift:16` |
| PDF OCR 배선 패턴(참고용 전례) | `ContentExtractor.localBody`가 PDF 분기 안에서 `guard ocrScannedPDFs else { return nil }` → `OCRService.recognizeText(in: pdf)` | `ContentExtractor.swift:28-29` |
| 설정 | `AppSettings.ocrScannedPDFsEnabled: Bool = false`(기본 꺼짐) + `SettingsView` 토글 1곳 | `Settings.swift:118`, `SettingsView.swift:820` |
| 색인 배선 | `SearchIndexer.indexFolder`/`.reindex`가 `ocrScannedPDFs` 매개변수를 받아 `ContentExtractor.body`에 그대로 전달 | `SearchIndexer.swift` |
| `AppState` 호출부 | `settings.ocrScannedPDFsEnabled`를 넘기는 곳 정확히 3곳 — `rebuildIndex`류(1908행), `registerIndexFolder`류(1919행), 재인덱싱 루프(1970행) | `AppState.swift:1908, 1919, 1970` |
| PDF OCR을 안 타는 다른 호출부 | `CleanupService`·`RagPassageExtractor`·`WikiIngestService`는 `ContentExtractor.body(for:kordoc:)`를 기본값(OCR 없음)으로만 호출 — **폴더 등록 색인 경로에만 OCR이 붙어 있고, 즉석 요약·RAG·위키 인제스트는 원래도 OCR을 안 탔다** | 각 파일 실제 호출부 |

→ 결론: 이미지 OCR도 **같은 자리(폴더 등록 색인 경로)에만** 붙이면 되고, 기존 관례(즉석 요약·RAG 등은 OCR 없이 그대로)를 그대로 따르는 게 일관적이다.

---

## 3. 설계 방향

### 3.1 새 설정 — 독립 토글

`AppSettings.ocrImagesEnabled: Bool = false` 신설. **`ocrScannedPDFsEnabled`와 통합하지 않고 별도로 둔다** — "스캔 PDF는 느려서 끄고 싶은데 사진은 원한다"(또는 반대) 케이스를 둘 다 받아준다. 기본 OFF(사진 많은 폴더 훑기가 느려질 위험 — PDF OCR 때와 같은 이유).

### 3.2 `ContentExtractor.localBody` 확장

```
static func localBody(for url: URL, ocrScannedPDFs: Bool = false, ocrImages: Bool = false) -> String?
```

이미지 분기 신설(PDF 분기 바로 아래, 텍스트 판정보다 먼저):

```
if DocumentKind.imageExtensions.contains(ext) {
    guard ocrImages else { return nil }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= maxOCRImageBytes else { return nil }   // 큰 사진 한 장이 폴더 훑기를 통째로 늦추는 것 방지
    guard let cgImage = OCRService.loadCGImage(from: url) else { return nil }
    return OCRService.recognizeText(in: cgImage)
}
```

- `maxOCRImageBytes`는 새 상수(제안 20MB — 확인 필요, §6-1). PDF의 `maxTextBytes`(5MB)와 별개 상수로 둔다 — 사진은 텍스트 파일보다 원래 크므로 같은 상한을 쓰면 대부분 걸러져 버린다.
- `OCRService.loadCGImage(from url:)` 신설(순수에 가까운 I/O 헬퍼) — `NSImage(contentsOf:)` → `cgImage(forProposedRect:context:hints:)`. PDF 쪽 `recognizeText(in pdfPage:)`가 이미 같은 변환을 하고 있어(썸네일→CGImage) 패턴 일관.
- gif는 첫 프레임만 인식(애니메이션 프레임별 OCR은 범위 밖).

### 3.3 `body(for:kordoc:)` 확장

```
static func body(for url: URL, kordoc: KordocService, ocrScannedPDFs: Bool = false, ocrImages: Bool = false) async -> String?
```

office 분기는 그대로, 그 외는 `localBody(for:ocrScannedPDFs:ocrImages:)`로 위임. **기존 호출부(`CleanupService`·`RagPassageExtractor`·`WikiIngestService`)는 매개변수를 안 넘기므로 기본값 `false`로 지금과 100% 동일하게 동작** — 회귀 없음.

### 3.4 `SearchIndexer` 확장

`indexFolder(_:ocrScannedPDFs:ocrImages:progress:)`·`reindex(path:ocrScannedPDFs:ocrImages:)` — 매개변수만 추가해 `ContentExtractor.body` 호출에 그대로 전달.

### 3.5 `AppState` 배선 (3곳, PDF OCR과 동일 위치)

`AppState.swift:1908, 1919, 1970` 세 호출부 각각에 `ocrImages: settings.ocrImagesEnabled` 추가.

### 3.6 설정 화면

`SettingsView.swift:820` PDF OCR 토글 바로 아래에:

```
Toggle("사진 속 글자도 읽기 (OCR)", isOn: $state.settings.ocrImagesEnabled)
```

footer 문구(824행)에 사진 OCR 설명 追加 — "사진(jpg·png·heic 등)도 켜면 안의 글자로 찾을 수 있다. 사진이 많은 폴더는 훑기가 느려질 수 있어 기본은 꺼둔다."

---

## 4. 파일 구조

**새로 만드는 파일 없음** — 이미 있는 서비스(`OCRService`·`ContentExtractor`·`SearchIndexer`·`AppState`·`Settings`·`SettingsView`)의 기존 함수를 확장하는 것만으로 끝난다. PDF OCR 때 이미 만든 인프라를 그대로 넓히는 작업이라 새 모델·새 뷰가 필요 없다.

| 파일 | 변경 |
|---|---|
| `Sources/Services/OCRService.swift` | `loadCGImage(from:)` 헬퍼 추가 |
| `Sources/Services/ContentExtractor.swift` | `maxOCRImageBytes` 상수 + `localBody`/`body` 이미지 분기 |
| `Sources/Services/SearchIndexer.swift` | `indexFolder`/`reindex`에 `ocrImages` 매개변수 |
| `Sources/App/AppState.swift` | 3개 호출부에 `ocrImages: settings.ocrImagesEnabled` 추가 |
| `Sources/Models/Settings.swift` | `ocrImagesEnabled` 필드 + Codable 디코드 |
| `Sources/Views/SettingsView.swift` | 토글 1개 + footer 문구 갱신 |
| `Tests/CmdMDTests/OCRServiceTests.swift` | `loadCGImage` 성공/실패, 이미지 OCR 켜짐/꺼짐, 크기 상한 테스트 추가 |

---

## 5. 이번에 하지 않을 것

- 이미지 리더 화면에 인식된 글자를 보여주거나 복사하는 기능(이번엔 검색 색인 목적만)
- 큰 사진 자동 축소(다운샘플링)로 속도 개선 — 크기 상한으로만 방어, 최적화는 후속
- "스캔 PDF OCR"과 "사진 OCR" 토글 통합
- `bmp`·`tiff` 등 `DocumentKind.imageExtensions`에 없는 형식 추가
- gif 애니메이션 프레임별 인식(첫 프레임만)
- 즉석 요약(Claude 우클릭 요약)·RAG·위키 인제스트 경로에 OCR 붙이기(기존 PDF OCR도 이 경로들엔 안 붙어 있음 — 일관성 유지)

---

## 6. 확인해 주실 것

1. 사진 파일 크기 상한 **20MB**로 괜찮은지 — 이보다 큰 사진(고해상도 스캔 등)은 이름만 색인되고 본문은 안 읽힘.
2. "스캔 PDF OCR"과 별개로 **독립 토글**을 만드는 방향에 동의하는지.
3. 이 설계로 실행 계획서(태스크 목록)를 써도 되는지.
