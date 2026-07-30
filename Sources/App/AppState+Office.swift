import Foundation

extension AppState {

    // MARK: - kordoc patch 편집 저장

    /// 변환 마크다운을 편집 버퍼로 복사하고 편집모드로 들어간다(이미 버퍼가 있으면 유지).
    /// 편집은 마크다운에서만 가능 — "원본 보기" 중이었으면 함께 끈다.
    @MainActor
    func beginOfficeEdit(tabID: UUID) {
        guard case .loaded(let result)? = officeStates[tabID] else { return }
        if officeEditBuffers[tabID] == nil {
            officeEditBuffers[tabID] = result.markdown
        }
        officeEditing.insert(tabID)
        officeShowingOriginal.remove(tabID)
    }

    /// "원본 보기" 켜고 끄기(격차 5번) — MS 오피스(doc/docx/xls/xlsx)는 QuickLook,
    /// hwpx는 kordoc render(SVG, 2026-07-29), hwp(구형)는 hwp-convert(2026-07-30)로 각각
    /// 그린다. 호출부(뷰)가 `canShowOriginal`로 이미 걸러 보이지만, 여기서도 같은 판정으로
    /// 한 번 더 막는다(단일 진실 원천 유지).
    @MainActor
    func toggleOfficeOriginalView(tabID: UUID, fileURL: URL) {
        let ext = fileURL.pathExtension.lowercased()
        guard DocumentKind.nativelyRenderableOfficeExtensions.contains(ext)
            || DocumentKind.kordocRenderableExtensions.contains(ext)
            || DocumentKind.hwpConvertRenderableExtensions.contains(ext) else { return }
        if officeShowingOriginal.contains(tabID) {
            officeShowingOriginal.remove(tabID)
        } else {
            officeShowingOriginal.insert(tabID)
            let needsRender = DocumentKind.kordocRenderableExtensions.contains(ext)
                || DocumentKind.hwpConvertRenderableExtensions.contains(ext)
            if needsRender, officeOriginalRenderStates[tabID] == nil {
                Task { await loadOfficeOriginalRender(tabID: tabID, fileURL: fileURL) }
            }
        }
    }

    /// 오피스 "원본 보기" 렌더를 확장자에 맞는 엔진(hwpx=kordoc render, hwp=hwp-convert)으로
    /// 받아온다. 실패해도 크래시하지 않고 `.failed` 상태로만 남는다(뷰가 "글로 보기로 전환"
    /// 버튼을 보여줌). hwp-convert는 실제 변환·추출이 WKWebView 안 JS에서 일어나 Swift가
    /// 성공 여부를 미리 알 수 없으므로, 여기서 `.failed`로 가는 건 파일을 아예 못 읽거나
    /// 번들 자산이 없을 때뿐이다(hwp-convert 자체의 실패는
    /// `HwpConvertRenderService.wrapExtractor`가 페이지 안에서 안내로 바꾼다).
    @MainActor
    func loadOfficeOriginalRender(tabID: UUID, fileURL: URL) async {
        officeOriginalRenderStates[tabID] = .loading
        let ext = fileURL.pathExtension.lowercased()
        do {
            let html: String
            if DocumentKind.hwpConvertRenderableExtensions.contains(ext) {
                html = try await hwpConvertRenderService.renderHTML(for: fileURL)
            } else {
                html = try await kordocRenderService.renderHTML(for: fileURL)
            }
            guard tabs.contains(where: { $0.id == tabID }) else { return }
            officeOriginalRenderStates[tabID] = .loaded(html: html)
        } catch {
            guard tabs.contains(where: { $0.id == tabID }) else { return }
            officeOriginalRenderStates[tabID] = .failed(Self.officeOriginalRenderErrorMessage(error))
        }
    }

    /// 편집을 취소하고 버퍼를 버린다.
    @MainActor
    func cancelOfficeEdit(tabID: UUID) {
        officeEditing.remove(tabID)
        officeEditBuffers[tabID] = nil
    }

    /// 기본 출력 경로를 제안해 저장 확인 시트를 띄운다(아직 쓰지 않는다).
    @MainActor
    func requestOfficeSave(tabID: UUID, fileURL: URL) {
        officeSaveConfirm = OfficeSaveRequest(tabID: tabID, fileURL: fileURL,
                                              output: Self.patchedOutputURL(for: fileURL))
    }

    /// 확인된 출력 경로로 kordoc patch를 실행한다. 원본은 건드리지 않는다.
    @MainActor
    func confirmOfficeSave(tabID: UUID, fileURL: URL, output: URL) {
        guard let edited = officeEditBuffers[tabID],
              !officePatchInProgress.contains(tabID) else { return }
        officeSaveConfirm = nil
        officePatchInProgress.insert(tabID)
        Task { @MainActor in
            do {
                try await kordocWriteService.patch(original: fileURL, editedMarkdown: edited, output: output)
                toastMessage = "서식 보존 저장됨: \(output.lastPathComponent)"
                officeEditing.remove(tabID)
                officeEditBuffers[tabID] = nil
            } catch {
                errorMessage = Self.kordocWriteErrorMessage(error)
            }
            officePatchInProgress.remove(tabID)
        }
    }

    static func kordocWriteErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocWriteError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocWriteError.timeout:
            return "서식 보존 저장이 너무 오래 걸려 중단했습니다."
        case KordocWriteError.patchFailed(let m):
            return "서식 보존 저장에 실패했습니다.\n\(m)"
        default:
            return "저장에 실패했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - kordoc fill 양식 채우기

    /// dry-run으로 서식 필드를 조회해 양식 채우기 시트를 띄운다(아직 채우지 않는다).
    @MainActor
    func beginOfficeFill(tabID: UUID, fileURL: URL) {
        guard DocumentKind.isFillable(fileURL),
              !officeFillInProgress.contains(tabID) else { return }
        officeFillInProgress.insert(tabID)
        Task { @MainActor in
            do {
                let detection = try await kordocFillService.dryRun(template: fileURL)
                officeFillSession = OfficeFillRequest(tabID: tabID, fileURL: fileURL,
                                                      detection: detection,
                                                      output: Self.filledOutputURL(for: fileURL))
            } catch {
                errorMessage = Self.kordocFillErrorMessage(error)
            }
            officeFillInProgress.remove(tabID)
        }
    }

    /// 확인된 값·출력 경로로 kordoc fill을 실행한다. 원본은 건드리지 않는다.
    @MainActor
    func confirmOfficeFill(tabID: UUID, fileURL: URL,
                           values: [String: String], output: URL) {
        guard !officeFillInProgress.contains(tabID) else { return }
        officeFillSession = nil
        officeFillInProgress.insert(tabID)
        Task { @MainActor in
            do {
                let warnings = try await kordocFillService.fill(template: fileURL,
                                                                values: values, output: output)
                if warnings.isEmpty {
                    toastMessage = "양식 채움: \(output.lastPathComponent)"
                } else {
                    toastMessage = "양식 채움: \(output.lastPathComponent) · 매칭 실패 \(warnings.count)개"
                }
            } catch {
                errorMessage = Self.kordocFillErrorMessage(error)
            }
            officeFillInProgress.remove(tabID)
        }
    }

    static func kordocFillErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocFillError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocFillError.timeout:
            return "양식 채우기가 너무 오래 걸려 중단했습니다."
        case KordocFillError.dryRunFailed(let m):
            return "서식 필드를 읽지 못했습니다.\n\(m)"
        case KordocFillError.fillFailed(let m):
            return "양식 채우기에 실패했습니다.\n\(m)"
        case KordocFillError.decodeFailed:
            return "서식 필드 정보를 해석하지 못했습니다."
        default:
            return "양식 채우기에 실패했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - Office Conversion

    /// office 탭 변환을 시작/재시도한다(로딩 표시 후 비동기 변환).
    @MainActor
    func retryOfficeConversion(tabID: UUID, fileURL: URL) {
        officeStates[tabID] = .loading
        Task { @MainActor in
            do {
                let result = try await kordocService.convert(fileURL: fileURL)
                guard tabs.contains(where: { $0.id == tabID }) else { return }
                officeStates[tabID] = .loaded(result)
            } catch {
                guard tabs.contains(where: { $0.id == tabID }) else { return }
                officeStates[tabID] = .failed(Self.officeErrorMessage(error))
            }
        }
    }

    /// 듀얼 페인 칸 미리보기 전용 — 탭 생명주기(officeStates[tabID])와 무관하게 변환만 한다
    /// (칸엔 탭ID가 없다). 같은 kordocService 인스턴스를 재사용해 세션 캐시 이득은 그대로 본다.
    func convertOfficeDocumentForPanePreview(fileURL: URL) async throws -> KordocResult {
        try await kordocService.convert(fileURL: fileURL)
    }

    static func officeErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocError.timeout:
            return "문서 변환 시간이 초과됐습니다. 다시 시도해 주세요."
        case KordocError.decodeFailed:
            return "변환 결과를 해석하지 못했습니다."
        case KordocError.conversionFailed(let m):
            return "문서 변환에 실패했습니다.\n\(m)"
        default:
            return "문서를 열 수 없습니다: \(error.localizedDescription)"
        }
    }

    /// 오피스 "원본 보기"(kordoc render / hwp-convert) 실패 사유를 한국어로 — `renderFailed`는
    /// kordoc이 이미 한국어 stderr를 주므로(예: "조판 캐시(linesegarray) 없음…") 그대로 보여준다.
    /// hwp-convert 쪽 실패(`HwpConvertRenderError`)는 파일을 못 읽거나 번들 자산이 없는 Swift
    /// 쪽 실패만 여기로 온다 — hwp-convert 자체의 실패는 페이지 안에서 처리된다(항상 `.loaded`).
    static func officeOriginalRenderErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocRenderError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocRenderError.timeout:
            return "원본 그리기 시간이 초과됐습니다. 다시 시도해 주세요."
        case KordocRenderError.renderFailed(let m):
            return m.isEmpty ? "원본을 그리지 못했습니다. 글로 보기를 이용해 주세요." : "\(m)\n글로 보기를 이용해 주세요."
        case HwpConvertRenderError.assetMissing:
            return "원본 보기에 필요한 구성요소를 찾을 수 없습니다. 앱을 다시 설치해 주세요."
        case HwpConvertRenderError.readFailed(let m):
            return "파일을 읽지 못했습니다: \(m)"
        default:
            return "원본을 그리지 못했습니다: \(error.localizedDescription)"
        }
    }
}
