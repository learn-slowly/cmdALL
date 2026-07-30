import SwiftUI

/// 한글·오피스 문서를 kordoc 변환 결과(마크다운)로 표시한다.
/// hwp/hwpx는 편집모드(편집 → kordoc patch로 서식 보존 저장)를 지원한다.
/// 상태: 변환 중 / 완료(읽기 프리뷰 또는 편집) / 실패(안내+재시도).
struct OfficeReaderView: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let fileURL: URL

    /// Docufinder 격차 5번 — MS 오피스(doc/docx/xls/xlsx)는 macOS 내장 QuickLook, hwpx는
    /// kordoc render(SVG, 2026-07-29 추가)로 각각 원본 조판을 그린다. hwp/hwpml은 이 토글
    /// 자체가 안 뜬다(§DocumentKind — kordoc에 hwp 렌더 기능이 없음, 실측 확인).
    private var canShowOriginal: Bool {
        let ext = fileURL.pathExtension.lowercased()
        return DocumentKind.nativelyRenderableOfficeExtensions.contains(ext)
            || DocumentKind.kordocRenderableExtensions.contains(ext)
    }

    var body: some View {
        switch appState.officeStates[tabID] {
        case .loaded(let result):
            let isEditing = appState.officeEditing.contains(tabID)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    if isEditing {
                        if appState.officePatchInProgress.contains(tabID) {
                            ProgressView().controlSize(.small)
                        }
                        Button("취소") { appState.cancelOfficeEdit(tabID: tabID) }
                            .disabled(appState.officePatchInProgress.contains(tabID))
                        Button("서식 보존 저장") {
                            appState.requestOfficeSave(tabID: tabID, fileURL: fileURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.officePatchInProgress.contains(tabID))
                    } else {
                        if canShowOriginal {
                            Button {
                                appState.toggleOfficeOriginalView(tabID: tabID, fileURL: fileURL)
                            } label: {
                                Label(appState.officeShowingOriginal.contains(tabID) ? "글로 보기" : "원본 보기",
                                      systemImage: "doc.richtext")
                            }
                        }
                        if DocumentKind.isPatchable(fileURL) {
                            Button {
                                appState.beginOfficeEdit(tabID: tabID)
                            } label: {
                                Label("편집", systemImage: "pencil")
                            }
                        }
                        if DocumentKind.isFillable(fileURL) {
                            if appState.officeFillInProgress.contains(tabID) {
                                ProgressView().controlSize(.small)
                            }
                            Button {
                                appState.beginOfficeFill(tabID: tabID, fileURL: fileURL)
                            } label: {
                                Label("양식 채우기", systemImage: "square.and.pencil")
                            }
                            .disabled(appState.officeFillInProgress.contains(tabID))
                        }
                    }
                }
                .padding(8)
                Divider()
                if isEditing {
                    OfficeEditorPane(tabID: tabID)
                } else if canShowOriginal && appState.officeShowingOriginal.contains(tabID) {
                    if DocumentKind.nativelyRenderableOfficeExtensions.contains(fileURL.pathExtension.lowercased()) {
                        QuickLookPreview(url: fileURL)
                    } else {
                        HwpxRenderPreview(tabID: tabID, fileURL: fileURL)
                    }
                } else {
                    MarkdownPreviewView(
                        documentID: tabID,
                        markdown: result.markdown,
                        // 사진이 있으면 kordoc이 뽑아낸 폴더를 기준 삼는다(2026-07-30 수정
                        // — 전엔 항상 원본 폴더를 기준 삼아 사진이 안 보였다).
                        baseURL: result.assetDirectory ?? fileURL.deletingLastPathComponent(),
                        options: appState.renderOptions(),
                        scrollSyncEnabled: false
                    )
                }
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("다시 시도") {
                    appState.retryOfficeConversion(tabID: tabID, fileURL: fileURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .loading, .none:
            VStack(spacing: 12) {
                ProgressView()
                Text("변환 중… (첫 실행은 kordoc 다운로드로 느릴 수 있어요)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 편집 버퍼(officeEditBuffers[tabID])를 마크다운 에디터로 보여준다. 위키링크 자동완성은 끈다.
private struct OfficeEditorPane: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let tabID: UUID

    private func editorFont() -> NSFont {
        let size = appState.settings.fontSize
        let name = appState.settings.fontName
        if !name.isEmpty, let custom = NSFont(name: name, size: size) { return custom }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var body: some View {
        let settings = appState.settings
        let theme = settings.editorTheme.resolved(forDark: colorScheme == .dark)
        MarkdownTextEditor(
            documentID: tabID,
            text: Binding(
                get: { appState.officeEditBuffers[tabID] ?? "" },
                set: { appState.officeEditBuffers[tabID] = $0 }
            ),
            font: editorFont(),
            editorTheme: theme,
            softWrap: settings.softWrap,
            showLineNumbers: settings.showLineNumbers,
            highlightCurrentLine: settings.highlightCurrentLine,
            tabSize: settings.tabSize,
            insertSpacesForTab: settings.insertSpacesInsteadOfTabs,
            enableCompletion: false,
            scrollSyncEnabled: false
        )
    }
}
