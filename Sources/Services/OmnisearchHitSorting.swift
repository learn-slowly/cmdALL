import Foundation

/// Omnisearch 파일명 결과 정렬(스펙 §5.1.1). relevance는 원본 순서를 그대로 둔다 —
/// fileHits가 이미 관련도/최근순으로 조립해 둔 순서를 이 함수가 흐트러뜨리지 않는다는 게 핵심 보장.
enum OmnisearchHitSorting {
    static func sorted(_ hits: [OmnisearchHit], by sort: OmnisearchSort) -> [OmnisearchHit] {
        guard sort.key != .relevance else { return hits }

        return hits.sorted { lhs, rhs in
            let result: ComparisonResult
            switch sort.key {
            case .relevance:
                result = .orderedSame // 도달 불가(위에서 선분기)
            case .name:
                result = lhs.title.localizedStandardCompare(rhs.title)
            case .path:
                result = lhs.subtitle.localizedStandardCompare(rhs.subtitle)
            case .size:
                result = compare(lhs.sizeBytes ?? 0, rhs.sizeBytes ?? 0)
            case .modifiedAt:
                result = compare(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast)
            }
            return sort.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
