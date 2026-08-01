import Foundation

/// 카드·문제 생성을 요청할 때 사용자가 고른 범위. "교재 전체를 한 번에 보내지 않는다"는
/// 설계 원칙(pre-mortem 1 — 범위 선택 필수화)을 지키기 위해 항상 있어야 한다.
/// `StudySourceLoader.segments(for:)`(예정)의 입력.
struct StudyScope: Equatable {
    let fileURL: URL
    let kind: DocumentKind
    let range: StudyScopeRange
}

/// 종류별 범위 표현(§5.2, 2026-08-01 I3로 오피스 확장). PDF는 쪽 범위, 마크다운·텍스트는
/// 줄 범위를 고를 수 있다. 오피스는 원본 파일 기준 위치 단위(쪽·줄)가 없어(변환 도구가
/// 안 준다) 대신 **변환된 글의 제목(헤딩) 단위**로 부분을 고를 수 있다(`.sectionRange`) —
/// 다만 근거 위치는 여전히 `.unknown`(원본 파일의 몇 쪽인지는 끝내 알 수 없다). 이미지는
/// 나눌 단위 자체가 없어(사진 한 장 = 학습 단위 하나) 파일 전체만 선택할 수 있다.
enum StudyScopeRange: Equatable {
    /// 1-based, 양끝 포함.
    case pageRange(Int, Int)
    /// 1-based, 양끝 포함.
    case lineRange(Int, Int)
    /// 1-based, 양끝 포함. 변환된 문서를 제목(헤딩) 경계로 나눈 "N번째 ~ M번째 구간".
    /// 헤딩이 하나도 없으면 문서 전체가 1구간이다.
    case sectionRange(Int, Int)
    case wholeFile
}
