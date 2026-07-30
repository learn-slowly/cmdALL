import SwiftUI

// MARK: - PaneReaderView

/// 듀얼 페인 칸 안 읽기 전용 미리보기(설계 §3.2) — 기존 렌더러를 그대로 재사용하되
/// 수정 기능은 없다. 고치려면 "이 창에서 제대로 열기"로 한 칸 모드의 정식 탭을 연다.
///
/// 이번 조각은 글자(md/txt 등)·이미지·PDF·QuickLook(못 여는 형식)까지 지원한다.
/// 오피스·미디어는 원본 렌더러가 편집(패치·양식 채우기·짝꿍 노트 편집) 버튼과 한 몸이라
/// 칸에서 그대로 쓰면 "읽기 전용" 약속이 깨진다 — 이번엔 이름·크기 요약만 보여주고
/// "이 창에서 제대로 열기"로 안내한다(후속 허용 — 필요하면 편집 없는 변형을 따로 만든다).
struct PaneReaderView: View {
    @Environment(AppState.self) private var appState
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

            Button("이 창에서 제대로 열기") {
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
        default:
            if QuickLookRouting.opensAsText(url) {
                textPreview
            } else {
                // 오피스·미디어 등 — 편집 UI와 한 몸이라 이번엔 요약만(위 문서 주석 참고).
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
            Text("이 칸에서는 훑어보기를 지원하지 않는 형식입니다. 위 \"이 창에서 제대로 열기\"로 여세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 48)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
