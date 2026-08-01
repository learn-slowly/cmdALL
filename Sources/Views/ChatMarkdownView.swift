import SwiftUI
import Markdown

/// 학습도우미 대화(S3) 턴을 마크다운으로 그린다 — AI 답이 흔히 쓰는 `**강조**`·목록·`` `코드` ``·
/// 인용·`###` 헤딩이 별표·해시 그대로 노출되지 않게 한다(레고 2026-08-01 피드백: "마크다운 문법이
/// 그대로 노출되는데?"). 문서 전체 미리보기가 쓰는 `MarkdownRenderer`(HTML+WKWebView, 표·수식·
/// Mermaid·코드 하이라이트까지 지원)는 대화창처럼 턴마다 자주 바뀌는 짧은 말풍선엔 무겁다
/// (웹뷰는 스트리밍 델타마다 재로드해야 하고, 턴이 많아지면 웹뷰도 여러 개 떠야 한다) — 그래서
/// 같은 파서(swift-markdown, 이미 프로젝트 의존성)로 직접 SwiftUI 뷰를 그리는 훨씬 가벼운
/// 네이티브 렌더러를 대화 전용으로 따로 둔다. 지원 범위는 대화 응답에 흔한 것만(문단·헤딩·
/// 굵게·기울임·인라인 코드·코드 블록·인용·순서/비순서 목록) — 표·수식·Mermaid·링크 강조 등
/// 문서 프리뷰 전용 기능은 의도적으로 생략(카드·문제 출력 계약 §O1~O3과도 무관).
///
/// `Markdown`과 `SwiftUI`가 둘 다 `Text`라는 이름을 쓴다 — 이 파일 안에서 `Text`는 항상
/// `SwiftUI.Text`, 마크다운 파서의 원소는 `Markdown.Text`로 명시해 구분한다.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        let document = Document(parsing: text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { _, block in
                Self.blockView(block)
            }
        }
    }

    // MARK: - 블록 단위

    // 재귀 호출(BlockQuote·목록이 자기 안에 다시 블록을 담을 수 있다)이 있어 `some View`로 두면
    // 컴파일러가 자기참조 오파크 타입을 못 푼다 — `AnyView`로 지운다(대화 말풍선 규모라 비용 무시 가능).
    private static func blockView(_ markup: Markup) -> AnyView {
        switch markup {
        case let heading as Heading:
            return AnyView(
                inlineText(heading)
                    .font(headingFont(level: heading.level))
                    .fontWeight(.semibold)
            )
        case let paragraph as Paragraph:
            return AnyView(inlineText(paragraph))
        case let codeBlock as CodeBlock:
            return AnyView(
                SwiftUI.Text(codeBlock.code.trimmingCharacters(in: .newlines))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
            )
        case let quote as BlockQuote:
            return AnyView(
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(quote.children.enumerated()), id: \.offset) { _, child in
                            blockView(child)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            )
        case let list as UnorderedList:
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(list.children.enumerated()), id: \.offset) { _, item in
                        if let listItem = item as? ListItem {
                            listItemRow(listItem, marker: "•")
                        }
                    }
                }
            )
        case let list as OrderedList:
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(list.children.enumerated()), id: \.offset) { index, item in
                        if let listItem = item as? ListItem {
                            listItemRow(listItem, marker: "\(index + 1).")
                        }
                    }
                }
            )
        default:
            // 지원 목록 밖(표·썸네일 이미지·HTML 블록 등) — 원문 그대로라도 보여준다(무동작보단 낫다).
            return AnyView(SwiftUI.Text(markup.format()))
        }
    }

    private static func listItemRow(_ item: ListItem, marker: String) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 6) {
                SwiftUI.Text(marker).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        blockView(child)
                    }
                }
            }
        )
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .subheadline
        }
    }

    // MARK: - 인라인(문단·헤딩 안 — 굵게·기울임·인라인 코드만, Text `+` 연결로 한 줄 조립)

    private static func inlineText(_ markup: Markup) -> SwiftUI.Text {
        markup.children.reduce(SwiftUI.Text("")) { $0 + inlineFragment($1) }
    }

    private static func inlineFragment(_ markup: Markup) -> SwiftUI.Text {
        switch markup {
        case let text as Markdown.Text:
            return SwiftUI.Text(text.string)
        case let strong as Strong:
            return strong.children.reduce(SwiftUI.Text("")) { $0 + inlineFragment($1) }.bold()
        case let emphasis as Emphasis:
            return emphasis.children.reduce(SwiftUI.Text("")) { $0 + inlineFragment($1) }.italic()
        case let code as InlineCode:
            return SwiftUI.Text(code.code).font(.system(.body, design: .monospaced))
        case let link as Markdown.Link:
            // 링크는 눌리지 않는 텍스트로만 보여준다(대화 말풍선에서 별도 탭 처리 없음) — 원문
            // URL은 생략하고 표시 텍스트만(비어 있으면 주소라도).
            let children = Array(link.children)
            let label = children.reduce(SwiftUI.Text("")) { $0 + inlineFragment($1) }
            return children.isEmpty ? SwiftUI.Text(link.destination ?? "") : label
        case is LineBreak, is SoftBreak:
            return SwiftUI.Text("\n")
        default:
            return SwiftUI.Text(markup.format())
        }
    }
}
