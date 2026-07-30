import Foundation

/// kordoc `--format json` 출력 모델. `style`/`metadata` 등 자유형식 키는
/// 선언하지 않으면 Codable이 자동으로 무시한다(필요 시 추후 추가).
struct KordocResult: Codable {
    let success: Bool
    let fileType: String
    let markdown: String
    let blocks: [KordocBlock]?
    let outline: [KordocOutlineItem]?
    /// 미리보기가 이미지를 찾을 기준 폴더 — kordoc은 markdown에 파일명만 적지만
    /// (예: `![image](image_001.png)`) 실제로는 이 폴더 밑에 뽑아낸다(실측 확인,
    /// 2026-07-30 — "images/" 접두어 없이 참조하는데 진짜 파일은 "images/" 하위에 생김).
    /// kordoc JSON엔 없는 필드라 디코드는 항상 nil로 안전하게 통과하고,
    /// `KordocService.convert(fileURL:)`가 변환 직후 채운다.
    var assetDirectory: URL? = nil
}

struct KordocBlock: Codable {
    let type: String
    let text: String?
    let pageNumber: Int?
    let level: Int?
}

struct KordocOutlineItem: Codable {
    let level: Int?
    let text: String?
    let pageNumber: Int?
}
