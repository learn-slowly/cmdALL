import SwiftUI
import AppKit
import PDFKit

/// 단독 PDF 보기. 상단 가로바(검색필드+회전버튼) 아래로 PDFView가 전체 폭을 쓴다.
/// PDFView가 페이지 이동·줌·맞춤·텍스트 선택/복사·회전을 제공하고,
/// NSSearchField가 문서 내 검색을 담당.
/// 로드 실패 시 플레이스홀더(크래시 금지).
///
/// 썸네일 칸(PDFThumbnailView)은 제거했다. 두 칸 분할이던 시절, 분할 폭 지정이
/// 최초 1회만 걸리는 반면 load(url:)는 매번 분할 뷰를 새로 만들어서 — 두 번째 PDF부터
/// 분할 폭이 미지정으로 남고 NSSplitView가 남는 폭을 첫 칸에 몰아줘 본문이 ~58pt로
/// 눌리는 결함이 있었다(실측: 첫 PDF 160/611, 이후 713/58). 게다가 썸네일 뷰는
/// 스크롤뷰 안에서 제약이 없어 프레임이 0x0이라 한 번도 그려진 적이 없었다.
///
/// 탭 전환으로 같은 인스턴스가 재사용되므로, 로드 로직은 Coordinator.load(url:)로 빼서
/// makeNSView가 항상 안정적인 container 하나를 반환하도록 한다(실패해도 같은 container를 유지하고,
/// 이후 유효 URL로 바뀌면 재로딩이 정상 동작).
/// PDFView도 NSView라 `menu(for:)`를 오버라이드하면 기본 컨텍스트 메뉴(복사·찾아보기 등)
/// 위에 항목을 더할 수 있다(`CmdMDTextView`와 같은 패턴, 2026-08-01 — 마우스로 블록 설정 후
/// 오른쪽 버튼으로도 AI 호출).
final class CmdMDPDFView: PDFView {
    var onAskAI: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        // 선택 여부는 super 호출 전에 캡처한다(CmdMDTextView와 같은 이유 — 부수효과 방지).
        let hasSelection = !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let base = super.menu(for: event)
        guard hasSelection, onAskAI != nil else { return base }
        let menu = base ?? NSMenu()
        if !menu.items.isEmpty {
            menu.insertItem(.separator(), at: 0)
        }
        let item = NSMenuItem(title: "Claude에게 물어보기", action: #selector(handleAskAI), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func handleAskAI() {
        onAskAI?()
    }
}

struct PDFReaderView: NSViewRepresentable {
    let url: URL
    /// 사용자가 PDF 안에서 드래그로 고른 텍스트(없으면 ""). Claude 질의 컨텍스트 우선순위 1로
    /// 쓰인다(2026-07-31 — 마크다운 에디터의 onSelectedTextChange와 같은 패턴). 다른 화면(듀얼
    /// 페인 미리보기 등)은 기본값을 그대로 둬 배선하지 않아도 된다.
    var onSelectedTextChange: (String) -> Void = { _ in }
    /// 선택 영역이 있을 때 우클릭 메뉴에 "Claude에게 물어보기"를 추가한다(2026-08-01).
    var onAskAI: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.container = container
        context.coordinator.onSelectedTextChange = onSelectedTextChange
        context.coordinator.onAskAI = onAskAI
        context.coordinator.load(url: url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 클로저는 SwiftUI가 렌더마다 새로 만들어 주므로 항상 최신으로 갱신(캡처된 appState 최신값 유지).
        context.coordinator.onSelectedTextChange = onSelectedTextChange
        context.coordinator.onAskAI = onAskAI
        // 탭 재사용으로 url이 바뀌면 재로딩(성공·실패 모두 load가 currentURL을 갱신해 재시도 폭주 방지).
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.load(url: url)
    }

    final class Coordinator: NSObject {
        weak var container: NSView?
        weak var pdfView: PDFView?
        weak var searchField: NSSearchField?
        var currentURL: URL?
        var matches: [PDFSelection] = []
        var matchIndex: Int = 0
        var lastQuery: String = ""
        var onSelectedTextChange: (String) -> Void = { _ in }
        var onAskAI: () -> Void = {}

        private var observers: [NSObjectProtocol] = []

        override init() {
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: .scrollToPDFPage, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let jump = note.object as? PDFPageJump,
                      jump.url == self.currentURL,
                      let pdfView = self.pdfView,
                      let document = pdfView.document,
                      jump.page >= 1, jump.page <= document.pageCount,
                      let page = document.page(at: jump.page - 1) else { return }
                pdfView.go(to: page)
            })
            observers.append(center.addObserver(
                forName: .PDFViewSelectionChanged, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let pdfView = self.pdfView,
                      (note.object as? PDFView) === pdfView else { return }
                self.onSelectedTextChange(pdfView.currentSelection?.string ?? "")
            })
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        /// url로 문서를 로드해 container의 뷰 트리를 구성한다. 재호출 가능(탭 전환·재시도).
        /// 실패해도 container 자체는 유지하고 플레이스홀더만 넣으므로, 이후 유효 URL 전환이 정상 복구된다.
        func load(url: URL) {
            guard let container else { return }

            // 1) currentURL을 무조건 먼저 갱신(실패해도 같은 나쁜 URL을 매번 재로딩하지 않게).
            currentURL = url

            // 2) 기존 뷰·검색 상태 초기화. 이전 문서의 선택영역이 새 문서로 새지 않게
            // onSelectedTextChange("")로 즉시 비운다(2026-07-31).
            container.subviews.forEach { $0.removeFromSuperview() }
            pdfView = nil
            searchField = nil
            matches = []
            matchIndex = 0
            lastQuery = ""
            onSelectedTextChange("")

            // 3) 로드 실패 시 플레이스홀더 라벨만 붙이고 종료.
            guard let document = PDFDocument(url: url) else {
                let label = NSTextField(labelWithString: "PDF를 열 수 없습니다")
                label.alignment = .center
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])
                return
            }

            // 4) 성공: 상단 가로바(검색+회전) + PDFView(전체 폭) 구성.
            let pdfView = CmdMDPDFView()
            pdfView.onAskAI = { [weak self] in self?.onAskAI() }
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            pdfView.translatesAutoresizingMaskIntoConstraints = false
            pdfView.document = document
            self.pdfView = pdfView

            // 검색 필드(상).
            let search = NSSearchField()
            search.placeholderString = "이 문서에서 검색"
            search.translatesAutoresizingMaskIntoConstraints = false
            search.target = self
            search.action = #selector(searchChanged(_:))
            self.searchField = search
            // 검색이 가로폭을 차지하도록(버튼은 고정).
            search.setContentHuggingPriority(.defaultLow, for: .horizontal)

            // 회전 버튼 2개(검색 우측).
            let rotateLeftButton = NSButton(
                image: NSImage(systemSymbolName: "rotate.left", accessibilityDescription: "왼쪽으로 회전") ?? NSImage(),
                target: self,
                action: #selector(rotateLeft(_:))
            )
            rotateLeftButton.bezelStyle = .texturedRounded
            rotateLeftButton.translatesAutoresizingMaskIntoConstraints = false
            rotateLeftButton.setContentHuggingPriority(.required, for: .horizontal)

            let rotateRightButton = NSButton(
                image: NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "오른쪽으로 회전") ?? NSImage(),
                target: self,
                action: #selector(rotateRight(_:))
            )
            rotateRightButton.bezelStyle = .texturedRounded
            rotateRightButton.translatesAutoresizingMaskIntoConstraints = false
            rotateRightButton.setContentHuggingPriority(.required, for: .horizontal)

            // 상단 가로바: 검색 + 회전 버튼.
            let topBar = NSStackView(views: [search, rotateLeftButton, rotateRightButton])
            topBar.orientation = .horizontal
            topBar.spacing = 6
            topBar.translatesAutoresizingMaskIntoConstraints = false

            // 상단 가로바 + PDFView 세로 스택(전체 폭).
            let stack = NSStackView(views: [topBar, pdfView])
            stack.orientation = .vertical
            stack.spacing = 0
            stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 6)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.setHuggingPriority(.defaultLow, for: .vertical)
            topBar.setContentHuggingPriority(.required, for: .vertical)

            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        /// 검색어 변경 시: 일치 목록을 갱신하고 첫 일치로 이동.
        /// 같은 검색어로 Enter를 반복하면 다음 일치로 순회한다.
        @objc func searchChanged(_ sender: NSSearchField) {
            guard let pdfView, let document = pdfView.document else { return }
            let text = sender.stringValue
            guard !text.isEmpty else {
                matches = []
                matchIndex = 0
                lastQuery = ""
                pdfView.highlightedSelections = nil
                return
            }
            if text == lastQuery, !matches.isEmpty {
                matchIndex = (matchIndex + 1) % matches.count
            } else {
                lastQuery = text
                matches = document.findString(text, withOptions: [.caseInsensitive])
                matchIndex = 0
            }
            guard !matches.isEmpty else {
                pdfView.highlightedSelections = nil
                return
            }
            pdfView.highlightedSelections = matches
            let current = matches[matchIndex]
            pdfView.setCurrentSelection(current, animate: true)
            pdfView.scrollSelectionToVisible(nil)
        }

        /// 현재 페이지를 왼쪽/오른쪽으로 90도 회전.
        /// PDFView의 rotatePageLeft/Right 공개 API는 버전 의존이 있어, PDFPage.rotation을 직접 조정한다.
        @objc func rotateLeft(_ sender: Any?) { rotate(by: -90) }
        @objc func rotateRight(_ sender: Any?) { rotate(by: 90) }
        private func rotate(by degrees: Int) {
            guard let pdfView, let page = pdfView.currentPage else { return }
            page.rotation += degrees           // PDFPage.rotation은 90단위, 음수/360+ 허용
            pdfView.layoutDocumentView()
        }
    }
}

/// 검색 결과(PDF 본문)에서 특정 페이지로 이동 요청. object로 PDFPageJump를 싣는다.
extension Notification.Name {
    static let scrollToPDFPage = Notification.Name("scrollToPDFPage")
}

/// 어떤 PDF의 몇 페이지로 갈지(1-base). 여러 PDF 탭 중 url로 대상 식별.
struct PDFPageJump {
    let url: URL
    let page: Int
}
