import Foundation

/// Omnisearch(⇧⌘O) 결과 한 줄. 파일명 매치(file)와 본문 매치(content) 공용.
/// 원래 OmnisearchView 안의 Hit이었으나, 정렬 로직(OmnisearchHitSorting)을
/// 뷰 밖에서 순수 함수로 테스트하기 위해 최상위 모델로 승격(스펙 §5.1).
struct OmnisearchHit: Identifiable {
    enum Kind {
        case file
        case content
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
    let line: Int?
}
