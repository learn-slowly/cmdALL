import Foundation

/// 진도 관리에서 "분량을 세는 단위". 교재 종류마다 셀 수 있는 것이 다르다(설계
/// `2026-08-02-study-progress-design.md` §목차 추출) — PDF는 쪽, 마크다운/텍스트는 줄,
/// 오피스(한글·워드)는 원본 위치를 알 수 없어 변환된 글의 "구간" 번호를 쓴다.
enum StudyOutlineUnit: String, Equatable, Codable {
    case page
    case line
    case section

    /// 화면·노트 제목에 쓰는 짧은 한국어 이름.
    var label: String {
        switch self {
        case .page: return "쪽"
        case .line: return "줄"
        case .section: return "구간"
        }
    }
}

/// 목차의 장(챕터) 하나. `start`/`end`는 `unit` 기준 1-based 양끝 포함 구간이고,
/// `read`/`done`은 사용자가 "여기까지 읽었다"고 체크한 상태다(진도 노트 앵커 줄에 저장된다 —
/// 진실의 출처는 언제나 파일, §3.1과 같은 원칙).
struct StudyOutlineChapter: Equatable, Identifiable {
    /// 1-based 순번. 진도 노트 앵커의 `no`이자 화면 표시 순서.
    let no: Int
    let title: String
    let start: Int
    let end: Int
    var read: Bool
    /// 읽음으로 표시한 날(선택). 표시를 지우면 nil로 되돌린다.
    var done: Date?
    /// 앵커 줄에서 우리가 모르는 키를 만나면 그대로 보존한다(기존 학습 앵커와 같은 계약).
    var extraTokens: [String]

    var id: Int { no }

    /// 이 장이 차지하는 분량(쪽 수·줄 수·구간 수). 뒤집힌 구간은 0.
    var length: Int { max(0, end - start + 1) }

    init(no: Int, title: String, start: Int, end: Int,
         read: Bool = false, done: Date? = nil, extraTokens: [String] = []) {
        self.no = no
        self.title = title
        self.start = start
        self.end = end
        self.read = read
        self.done = done
        self.extraTokens = extraTokens
    }
}

/// 교재 한 권의 목차 전체.
struct StudyOutline: Equatable {
    let unit: StudyOutlineUnit
    /// 총 분량(쪽 수·줄 수·구간 수). 진도 계산의 분모.
    let total: Int
    let chapters: [StudyOutlineChapter]

    var isEmpty: Bool { chapters.isEmpty }
}
