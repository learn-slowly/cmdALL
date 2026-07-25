import Foundation

/// 사용자가 직접 등록한 "빠른 이동" 목적지 폴더 (스펙 §4.1).
/// 즐겨찾기(`FavoriteItem`, "열어볼 곳")와 성격이 달라 별도 타입·별도 저장소로 둔다.
struct QuickMoveFolder: Identifiable, Equatable, Codable {
    let id: UUID
    var url: URL
    var addedAt: Date

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
    }
}
