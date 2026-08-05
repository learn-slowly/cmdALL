import Foundation

// MARK: - MainMode

/// 메인 에디터 영역의 모드. reader = 파일 리더, library = 폴더 라이브러리 뷰,
/// tasks = 할일 목록(간트차트), progress = 교재 진도, study = 학습도우미(카드·문제 만들기),
/// review = 오늘 복습. 레고 요청(2026-08-01) — 할일 화면을 팝업 시트가 아니라 파일 화면처럼
/// 메인 창 전체를 쓰는 정식 모드로 승격했고, 진도 화면(2026-08-02 "교재 목차를 가지고 전체
/// 진도 관리")에 이어 학습도우미·복습 화면도 같은 방식으로 올렸다(다듬기 C, 2026-08-02).
enum MainMode: String, Codable, CaseIterable {
    case reader
    case library
    case tasks
    case progress
    case study
    case review
    /// 이미 만들어 둔 문제집(100제 등)을 눌러서 푸는 화면(2026-08-05).
    case quiz
}

// MARK: - LibraryLayout

/// 라이브러리 뷰 레이아웃. grid = 격자, list = 목록.
enum LibraryLayout: String, Codable, CaseIterable {
    case grid
    case list
}
