import Foundation

/// "문서에서 할일 찾기 → Todoist 전송" 이력을 JSON 파일로 영속한다(전례: `MoveLogStore`).
/// 너무 커지지 않게 최근 200건만 유지 — 오래된 기록은 조용히 잘린다(경고 없음, 이력일 뿐
/// 되돌리기 대상이 아니므로 손실 허용).
actor SentTaskLogStore {
    private let fileURL: URL
    private static let maxRecords = 200

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("sent-tasks-log.json")
    }

    func load() -> [SentTaskRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([SentTaskRecord].self, from: data) else { return [] }
        return records
    }

    /// 최신순으로 정렬해 돌려준다(화면 표시용 편의).
    func loadNewestFirst() -> [SentTaskRecord] {
        load().sorted { $0.sentAt > $1.sentAt }
    }

    func append(_ record: SentTaskRecord) {
        var all = load()
        all.append(record)
        if all.count > Self.maxRecords {
            all.removeFirst(all.count - Self.maxRecords)
        }
        save(all)
    }

    private func save(_ records: [SentTaskRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
