import SwiftUI
import Quartz
import AppKit

/// 애플 미리보기(QuickLook)를 담는 컨테이너.
/// QLPreviewView 생성이 실패할 수 있어(failable) 컨테이너가 감싸 안전하게 다룬다.
final class QuickLookContainerView: NSView {
    private var preview: QLPreviewView?
    /// 미리보기 부품을 못 만들었는가 — 화면이 백지로 남지 않게 안내를 띄운다(스펙 §4).
    private(set) var failed = false

    func show(_ url: URL) {
        if preview == nil && !failed {
            guard let view = QLPreviewView(frame: bounds, style: .normal) else {
                failed = true
                return
            }
            view.autostarts = true
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            preview = view
        }
        preview?.previewItem = url as NSURL
    }

    /// 뷰가 사라질 때 반드시 부른다 — QuickLook 자원을 놓아준다.
    func teardown() {
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
    }
}

/// SwiftUI에 얹는 껍데기.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QuickLookContainerView {
        let view = QuickLookContainerView()
        view.show(url)
        return view
    }

    func updateNSView(_ nsView: QuickLookContainerView, context: Context) {
        nsView.show(url)
    }

    static func dismantleNSView(_ nsView: QuickLookContainerView, coordinator: ()) {
        nsView.teardown()
    }
}

/// 이 파일을 여는 기본 앱 이름 — 버튼 문구용.
enum DefaultAppInfo {
    /// 기본 앱이 없거나 그게 우리 자신이면 nil(버튼을 숨긴다).
    static func openerName(for url: URL) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        if appURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return nil }
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.isEmpty ? nil : name
    }
}

/// 우리가 모르는 형식의 탭 화면 — 애플 미리보기 + 위쪽 버튼 줄(스펙 §4).
struct QuickLookReaderView: View {
    let tabID: UUID
    let url: URL
    @Environment(AppState.self) private var appState
    @State private var openerName: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let name = openerName {
                    Button("\(name)으로 열기") { NSWorkspace.shared.open(url) }
                }
                Button("글로 열기") {
                    Task { await appState.reopenAsText(tabID: tabID) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // 안내를 뒤에 깔고 미리보기를 위에 얹는다 — 미리보기를 못 만들면
            // 아무것도 덮이지 않아 안내가 그대로 보인다(백지 방지, 스펙 §4).
            ZStack {
                VStack(spacing: 6) {
                    Image(systemName: "doc.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("이 형식은 미리보기를 만들 수 없습니다.")
                        .foregroundStyle(.secondary)
                    Text("위의 버튼으로 다른 앱에서 열어 보세요.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                QuickLookPreview(url: url)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) {
            // NSWorkspace 조회는 디스크를 볼 수 있어 메인에서 붙들지 않는다.
            let name = await Task.detached { DefaultAppInfo.openerName(for: url) }.value
            openerName = name
        }
    }
}
