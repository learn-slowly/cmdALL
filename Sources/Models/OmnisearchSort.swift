import Foundation

/// Omnisearch 표(스펙 §5.3) 정렬 키. relevance = 지금과 같은 기본 순서(최근파일/이름유사도).
enum OmnisearchSortKey {
    case relevance, name, path, size, modifiedAt
}

/// 정렬 상태(키+방향). `LibrarySort`(라이브러리 화면)와 같은 토글 규칙이지만,
/// 이 값은 세션 한정 — 저장하지 않는다(팝업이 닫히면 사라짐).
struct OmnisearchSort: Equatable {
    var key: OmnisearchSortKey
    var ascending: Bool

    init(key: OmnisearchSortKey = .relevance, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    static let `default` = OmnisearchSort()

    /// 키별 기본 방향 — 이름·경로는 오름차순, 크기·수정일은 내림차순(큰 것/최신 것 먼저).
    static func defaultAscending(for key: OmnisearchSortKey) -> Bool {
        switch key {
        case .size, .modifiedAt: return false
        case .relevance, .name, .path: return true
        }
    }

    /// 헤더 버튼이 공유하는 전이 규칙 — 같은 키 재클릭은 방향 반전, 다른 키는 그 키 기본 방향.
    func selecting(_ newKey: OmnisearchSortKey) -> OmnisearchSort {
        if newKey == key {
            return OmnisearchSort(key: key, ascending: !ascending)
        }
        return OmnisearchSort(key: newKey, ascending: Self.defaultAscending(for: newKey))
    }
}
