import Foundation

/// 학습도우미가 만든 카드·문제·발췌가 원본 문서의 어디를 가리키는지.
/// PDF는 쪽(page), 마크다운·텍스트는 줄(line), 오피스(한글·워드)는 kordoc이 변환한 글의
/// **몇 번째 구간**(section) — 원본 쪽수는 끝내 알 수 없지만 구간 번호는 셀 수 있다
/// (2026-08-02 진도 연결). 그래도 알 수 없으면 `.unknown`.
/// 모두 1-based(설계 문서 §5.1) — PDFKit 인덱스는 +1해서 담는다.
enum StudyLocator: Equatable, Hashable {
    case page(Int)
    case pageRange(Int, Int)
    case line(Int)
    case section(Int)
    case unknown
}

/// `StudySourceLoader`(예정)가 원본에서 뽑아낸 본문 한 조각 + 그 조각의 위치.
/// 청크로 묶이기 전 최소 단위(예: PDF 한 쪽, 마크다운 한 문단).
struct StudySegment: Equatable {
    let text: String
    let locator: StudyLocator
}

/// `StudyChunker`(예정)가 세그먼트를 글자 수 예산에 맞게 묶은 결과.
/// AI에게 한 번에 보낼 단위이자, 인용 검증(§O4)에서 "청크 밖 인용"을 가리는 기준(`coveredLocators`).
struct StudyChunk: Equatable {
    let body: String
    let coveredLocators: [StudyLocator]
    let charCount: Int
}
