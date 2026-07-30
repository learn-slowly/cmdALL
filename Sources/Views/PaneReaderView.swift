import SwiftUI

// MARK: - PaneReaderView

/// 듀얼 페인 칸 안 읽기 전용 미리보기(설계 §3.2) — 기존 렌더러를 그대로 재사용하되
/// 수정 기능은 없다. 고치려면 "큰 화면에서 보기"로 한 칸 모드의 정식 탭을 연다.
///
/// 이번 조각은 글자(md/txt 등)·이미지·PDF·QuickLook(못 여는 형식)까지 지원한다.
/// 오피스·미디어는 원본 렌더러가 편집(패치·양식 채우기·짝꿍 노트 편집) 버튼과 한 몸이라
/// 칸에서 그대로 쓰면 "읽기 전용" 약속이 깨진다 — 이번엔 이름·크기 요약만 보여주고
/// "큰 화면에서 보기"로 안내한다(후속 허용 — 필요하면 편집 없는 변형을 따로 만든다).
struct PaneReaderView: View {
    @Environment(AppState.self) private var appState
    @State private var officeState: PaneOfficePreviewState = .loading
    let paneIndex: Int
    let url: URL

    private var kind: DocumentKind { DocumentKind(from: url) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                appState.closePeekFile(in: paneIndex)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("목록으로 돌아가기")

            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button("큰 화면에서 보기") {
                appState.promotePeekFileToTab(url)
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .image:
            ImageReaderView(url: url)
        case .pdf:
            PDFReaderView(url: url)
        case .quickLook:
            QuickLookPreview(url: url)
        case .office:
            officePreview
        default:
            if QuickLookRouting.opensAsText(url) {
                textPreview
            } else {
                // 미디어(음악·동영상) 등 — 재생 UI가 편집·짝꿍노트 편집과 한 몸이라 이번엔 요약만.
                summaryPlaceholder
            }
        }
    }

    private var textPreview: some View {
        Group {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                MarkdownPreviewView(
                    documentID: nil,
                    markdown: text,
                    baseURL: url.deletingLastPathComponent(),
                    options: appState.renderOptions(),
                    scrollSyncEnabled: false
                )
            } else {
                summaryPlaceholder
            }
        }
    }

    /// 오피스·미디어 등 요약 화면 — 위쪽에 붙어야 한다(사용자 지적, 2026-07-30):
    /// `ContentUnavailableView`는 주어진 공간 전체를 차지하며 내용을 세로 가운데 정렬해
    /// 칸이 길면 툴바 바로 아래 큰 빈 공간이 생긴다. 직접 조립해 `alignment: .top`으로 고정한다.
    private var summaryPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("이 칸에서는 훑어보기를 지원하지 않는 형식입니다. 위 \"큰 화면에서 보기\"로 여세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 48)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 오피스·한글 문서 미리보기(사용자 요청, 2026-07-30) — 탭 없이 칸에서 바로 변환·표시.
    /// 원본 그대로 보기(hwpx 조판 렌더)·양식 채우기·편집은 탭 전용 기능이라 이번엔 뺀다 —
    /// 여기는 kordoc이 뽑아낸 글자·표·이미지를 읽기 전용으로만 보여준다.
    private var officePreview: some View {
        Group {
            switch officeState {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("변환 중… (첫 실행은 kordoc 다운로드로 느릴 수 있어요)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let markdown, let assetDirectory):
                MarkdownPreviewView(
                    documentID: nil,
                    markdown: markdown,
                    // 사진이 있으면 kordoc이 뽑아낸 폴더를 기준 삼는다(2026-07-30 수정).
                    baseURL: assetDirectory ?? url.deletingLastPathComponent(),
                    options: appState.renderOptions(),
                    scrollSyncEnabled: false
                )
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("다시 시도") {
                        Task { await loadOfficePreview() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .task(id: url) {
            await loadOfficePreview()
        }
    }

    @MainActor
    private func loadOfficePreview() async {
        officeState = .loading
        do {
            let result = try await appState.convertOfficeDocumentForPanePreview(fileURL: url)
            officeState = .loaded(result.markdown, result.assetDirectory)
        } catch {
            officeState = .failed(AppState.officeErrorMessage(error))
        }
    }
}

private enum PaneOfficePreviewState {
    case loading
    case loaded(String, URL?)
    case failed(String)
}
