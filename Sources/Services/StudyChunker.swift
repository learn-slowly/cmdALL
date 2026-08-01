import Foundation

/// 조각(`StudySegment`) 배열을 AI에게 한 번에 보낼 수 있는 크기(글자 수 예산)로 묶는다
/// (설계 §5.1·§5.3). 각 조각은 원래 위치를 담은 위치 태그(`[[p12]]`/`[[l345]]`/`[[?]]`)를
/// 앞에 붙인 채로 청크 본문에 들어가고, 그 태그·구분자 길이까지 예산 계산에 포함된다
/// (§4.2.5) — AI가 카드·문제에 인용을 남길 때 이 태그를 그대로 되돌려 쓴다(O1).
///
/// 조각 하나가 예산보다 커서 통째로는 어느 청크에도 못 들어가면(강제 분할), 그 조각의
/// 글자 자체를 예산 안에 들어가는 크기로 잘라 나눈다 — 잘린 조각들은 전부 원래 위치를
/// 그대로 물려받는다("locator 승계", 어차피 같은 쪽·줄에서 나온 글이라 위치는 하나다).
/// 세그먼트 경계(헤딩·페이지)는 예산이 허락하는 한 유지된다 — 여러 조각이 한 청크에
/// 들어가도 각자 자기 태그를 단 채로 이어붙을 뿐, 조각끼리 태그 없이 뭉개지지 않는다.
enum StudyChunker {
    private static let separator = "\n\n"

    static func chunks(from segments: [StudySegment], budget: Int) -> [StudyChunk] {
        guard budget > 0, !segments.isEmpty else { return [] }

        var chunks: [StudyChunk] = []
        var pieces: [(tagged: String, locator: StudyLocator)] = []
        var length = 0

        func flush() {
            guard !pieces.isEmpty else { return }
            let body = pieces.map(\.tagged).joined(separator: separator)
            chunks.append(StudyChunk(body: body, coveredLocators: pieces.map(\.locator), charCount: body.count))
            pieces = []
            length = 0
        }

        for segment in segments {
            let tag = tagString(for: segment.locator)
            let tagged = "\(tag) \(segment.text)"
            let additional = pieces.isEmpty ? tagged.count : separator.count + tagged.count

            if length + additional <= budget {
                pieces.append((tagged, segment.locator))
                length += additional
                continue
            }

            flush() // 지금 청크엔 안 들어간다 — 청크를 끊고 새로 시작.

            if tagged.count <= budget {
                pieces.append((tagged, segment.locator))
                length = tagged.count
                continue
            }

            // 강제 분할: 새 청크에서도 이 조각 하나가 예산을 넘는다 — 글자 자체를 자른다.
            let prefixLength = tag.count + 1 // "태그 " 뒤에 최소 1글자는 실어야 진행이 된다.
            let maxTextLength = max(1, budget - prefixLength)
            var remaining = Substring(segment.text)
            while !remaining.isEmpty {
                let piece = remaining.prefix(maxTextLength)
                remaining = remaining.dropFirst(piece.count)
                let pieceBody = "\(tag) \(piece)"
                chunks.append(StudyChunk(body: pieceBody, coveredLocators: [segment.locator], charCount: pieceBody.count))
            }
        }
        flush()
        return chunks
    }

    private static func tagString(for locator: StudyLocator) -> String {
        switch locator {
        case .page(let n):
            return "[[p\(n)]]"
        case .pageRange(let a, let b):
            return "[[p\(a)-\(b)]]"
        case .line(let n):
            return "[[l\(n)]]"
        case .unknown:
            return "[[?]]"
        }
    }
}
