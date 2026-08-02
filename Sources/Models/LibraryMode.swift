import Foundation

// MARK: - MainMode

/// 메인 에디터 영역의 모드. reader = 파일 리더, library = 폴더 라이브러리 뷰,
/// tasks = 할일 목록(간트차트), progress = 교재 진도. 레고 요청(2026-08-01) — 할일 화면을
/// 팝업 시트가 아니라 파일 화면처럼 메인 창 전체를 쓰는 정식 모드로 승격했고, 진도 화면도
/// 같은 방식으로 넣었다(2026-08-02 "교재 목차를 가지고 전체 진도 관리").
enum MainMode: String, Codable, CaseIterable {
    case reader
    case library
    case tasks
    case progress
}

// MARK: - LibraryLayout

/// 라이브러리 뷰 레이아웃. grid = 격자, list = 목록.
enum LibraryLayout: String, Codable, CaseIterable {
    case grid
    case list
}
