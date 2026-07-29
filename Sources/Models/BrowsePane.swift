import Foundation

/// 두 폴더 나란히 보기(듀얼 페인, 로드맵 C/F4)의 칸 하나.
/// 순수 값 타입 — AppState가 정확히 2개를 배열로 들고 있는다(`AppState.panes`).
struct BrowsePane: Equatable {
    /// 이 칸의 뿌리 폴더(듀얼 페인을 켤 때 currentFolder로 초기화).
    var rootFolder: URL
    /// 이 칸이 지금 보여주는 폴더(뿌리 밑 어딘가, 또는 뿌리 자신).
    var selectedFolder: URL
    /// 이 칸의 격자/목록 보기.
    var layout: LibraryLayout
    /// 이 칸의 정렬 상태.
    var sort: LibrarySort
    /// 이 칸 안에서 읽기 전용으로 열어본 파일(없으면 목록만 표시, 스펙 §3.2).
    var peekFile: URL?

    init(rootFolder: URL,
         selectedFolder: URL? = nil,
         layout: LibraryLayout = .list,
         sort: LibrarySort = LibrarySort(key: .para, ascending: true),
         peekFile: URL? = nil) {
        self.rootFolder = rootFolder
        self.selectedFolder = selectedFolder ?? rootFolder
        self.layout = layout
        self.sort = sort
        self.peekFile = peekFile
    }

    /// 폴더 드릴인/이동 — selectedFolder만 바뀌고 rootFolder는 유지한다.
    mutating func open(folder: URL) {
        selectedFolder = folder
    }

    /// 파일을 읽기 전용으로 열어본다(수정 없음, §3.2).
    mutating func peek(_ url: URL) {
        peekFile = url
    }

    /// 미리보기를 닫고 목록으로 돌아간다.
    mutating func clearPeek() {
        peekFile = nil
    }
}
