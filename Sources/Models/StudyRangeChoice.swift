import Foundation

/// 학습도우미 부분 범위 선택 화면(레고 2026-08-01 피드백 — "교재 전체를 한 번에 넣는 건
/// 비현실적"에 대응)에서 마크다운/텍스트 파일의 헤딩 하나를 고를 수 있는 단위로 보여준다.
/// `lineNumber`는 원본 파일의 실제 줄 번호(`TOCHeading.lineNumber` 그대로) — 사용자가 시작·끝
/// 헤딩을 고르면 이 값으로 `StudyScopeRange.lineRange`를 계산한다.
struct StudyHeadingChoice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let lineNumber: Int
}

/// 같은 화면에서 오피스(한글·워드) 문서의 구간 하나를 고를 수 있는 단위. `index`는
/// `StudySourceLoader.labeledSections`가 매긴 1-based 구간 번호이자 `StudyScopeRange.sectionRange`에
/// 그대로 넘길 수 있는 값(빈 구간을 건너뛴 뒤의 번호라 헤딩 목록 순번과 다를 수 있음).
struct StudySectionChoice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let index: Int
}
