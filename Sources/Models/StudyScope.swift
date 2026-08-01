import Foundation

/// 카드·문제 생성을 요청할 때 사용자가 고른 범위. "교재 전체를 한 번에 보내지 않는다"는
/// 설계 원칙(pre-mortem 1 — 범위 선택 필수화)을 지키기 위해 항상 있어야 한다.
/// `StudySourceLoader.segments(for:)`(예정)의 입력.
struct StudyScope: Equatable {
    let fileURL: URL
    let kind: DocumentKind
    let range: StudyScopeRange
}

/// 종류별 범위 표현(§5.2). PDF는 쪽 범위, 마크다운·텍스트는 줄 범위를 고를 수 있고,
/// 오피스·이미지는 위치 단위가 없어(§5.2 `.unknown`) 파일 전체만 선택할 수 있다.
enum StudyScopeRange: Equatable {
    /// 1-based, 양끝 포함.
    case pageRange(Int, Int)
    /// 1-based, 양끝 포함.
    case lineRange(Int, Int)
    case wholeFile
}
