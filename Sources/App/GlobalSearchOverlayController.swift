import SwiftUI
import AppKit

/// 다른 앱을 보고 있어도 ⌃⌘Space로 화면 중앙에 띄우는 파일 찾기(Raycast식) — PRD §10
/// "전역 단축키 파일 찾기" 구현. 이미 있는 ⌘⇧8(`AppState.showOmnisearchGlobal`)은 cmdALL
/// 메인 창 전체를 앞으로 불러오는 방식이라, 다른 앱 작업을 방해한다. 이건 그 대신 독립
/// `NSPanel`에 기존 `OmnisearchView`를 그대로 얹어 cmdALL을 활성화하지 않고 띄운다
/// (`.nonactivatingPanel` — Apple 문서: 이 패널이 key가 돼도 소유 앱은 활성화되지 않는다).
/// Esc나 바깥 클릭으로 닫히면 원래 보던 앱으로 그대로 복귀한다(cmdALL이 앞에 나서지 않음).
@MainActor
final class GlobalSearchOverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        let width: CGFloat = 760, height: CGFloat = 480
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            // Spotlight처럼 화면 정중앙보다 살짝 위(황금분할 지점 근처)에 뜬다.
            let origin = NSPoint(
                x: frame.midX - width / 2,
                y: frame.midY - height / 2 + frame.height * 0.12
            )
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = OverlaySearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // 등록된 다른 Space·전체화면 앱 위에서도 눌러 뜨게(다른 런처 앱들과 동일 관례).
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }

        let content = OmnisearchView(onRequestClose: { [weak self] in self?.hide() })
            .environment(appState)
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    /// 바깥(다른 앱·다른 창)을 클릭하면 key를 잃는다 — Spotlight/Raycast와 같이 조용히 닫는다.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }
}

/// `.nonactivatingPanel`이어도 borderless 패널은 기본적으로 key가 될 수 없어(AppKit 기본값)
/// override가 필요하다 — `canBecomeKey`가 true라야 안의 SwiftUI 텍스트필드가 실제로
/// 타이핑을 받는다. `cancelOperation`은 AppKit이 Esc를 다른 응답자가 안 먹었을 때
/// 흘려보내는 표준 경로 — `PaletteTextField`가 자체 처리하지만 이중 안전장치로 둔다.
private final class OverlaySearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
