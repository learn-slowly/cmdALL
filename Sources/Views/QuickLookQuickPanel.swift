import SwiftUI
import AppKit

/// 스페이스바 빠른 보기(스펙 §5) — 탭을 만들지 않고 크게 훑어본다.
///
/// **시트가 아니라 오버레이인 이유**: 떠 있는 시트는 `NSApp.terminate`를 막는다
/// (자동 업데이트 '지금 다시 시작' 사고에서 실측·변이 시험으로 확정). 빠른 보기를
/// 열어 둔 채 업데이트 재시작을 누르면 같은 증상이 재현되므로 오버레이로 둔다.
struct QuickLookQuickPanel: View {
    @Environment(AppState.self) private var appState

    private var currentURL: URL? {
        guard appState.quickLookURLs.indices.contains(appState.quickLookIndex) else { return nil }
        return appState.quickLookURLs[appState.quickLookIndex]
    }

    var body: some View {
        if appState.isQuickLookPresented, let url = currentURL {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { appState.closeQuickLook() }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if appState.quickLookURLs.count > 1 {
                            Text("\(appState.quickLookIndex + 1) / \(appState.quickLookURLs.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            appState.closeQuickLook()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("닫기 (스페이스 또는 esc)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    QuickLookPreview(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: 900, maxHeight: 700)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .padding(40)
            }
            .transition(.opacity)
        }
    }
}
