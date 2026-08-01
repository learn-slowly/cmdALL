import Foundation

/// "할일 목록 보기" 화면의 두 탭 — 레고 결정("둘 다"): Todoist 실시간 목록 + 이 앱이 보낸 기록.
enum TaskListTab: String, Equatable, CaseIterable {
    case todoist
    case sentHistory
}
