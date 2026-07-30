import Foundation

/// 위키 인제스트 적용 기록 한 건. backupFile은 wiki-backups/ 안 파일명 — 새 페이지
/// 생성이면 nil(복원 = 휴지통 이동). resultFile은 변경 "후" 본문 스냅샷 파일명 —
/// 이 필드 도입 전 구 기록은 nil(옵셔널 프로퍼티는 Swift 합성 Codable이 자동으로
/// decodeIfPresent/encodeIfPresent를 쓰므로 키 없는 구 JSON도 그대로 읽힌다).
struct WikiIngestLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let pageURL: URL
    let backupFile: String?
    let resultFile: String?
    let sourceName: String
    let date: Date
}

/// 덮어쓰기 직전 본 백업·기록·복원(스펙 §2.4). 앱 데이터 디렉터리에만 쓴다 —
/// 볼트 안엔 잡파일을 만들지 않는다. 복원도 삭제 없음(새 페이지는 휴지통).
actor WikiBackupStore {
    private let backupsDir: URL
    private let logURL: URL
    private var entries: [WikiIngestLogEntry]

    init(directory: URL) {
        backupsDir = directory.appendingPathComponent("wiki-backups")
        logURL = directory.appendingPathComponent("wiki-ingest-log.json")
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: logURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([WikiIngestLogEntry].self, from: data) {
                entries = loaded
            } else {
                entries = []
            }
        } else {
            entries = []
        }
    }

    /// 적용 직전 호출 — oldBody가 있으면 백업 파일로 저장하고 로그에 기록한다.
    func recordApply(pageURL: URL, oldBody: String?, sourceName: String) throws -> WikiIngestLogEntry {
        let now = Date()   // 백업 파일명 stamp와 로그 date가 같은 시각을 가리키도록 한 번만 읽는다.
        var backupFile: String? = nil
        if let oldBody {
            let stamp = Self.timestampFormatter.string(from: now)
            let base = pageURL.deletingPathExtension().lastPathComponent
            let file = backupsDir.appendingPathComponent("\(base)-\(stamp).md").uniquified()
            try oldBody.write(to: file, atomically: true, encoding: .utf8)
            backupFile = file.lastPathComponent
        }
        // Date를 초 단위로 반올림 — JSON 인코딩/디코딩 정밀도 맞춤
        let roundedDate = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded())
        let entry = WikiIngestLogEntry(
            id: UUID(), pageURL: pageURL, backupFile: backupFile, resultFile: nil,
            sourceName: sourceName, date: roundedDate)
        entries.append(entry)
        do {
            try persist()
        } catch {
            // 로그를 못 쓰면 기록 없는 고아 백업이 남는다 — 항목과 백업 파일을 되물리고 실패를 알린다.
            entries.removeLast()
            if let backupFile {
                try? FileManager.default.removeItem(at: backupsDir.appendingPathComponent(backupFile))
            }
            throw error
        }
        return entry
    }
    /// 인제스트 적용·복원 양쪽 모두, 파일 쓰기 "성공 직후" 호출 — 변경 후 본문을 결과
    /// 파일로 저장하고 항목에 붙인다. 5단계 원자성(고정 순서): entry 조회 → 결과 파일명
    /// 확정 → 결과 파일 쓰기 → 메모리 entry 갱신 → persist. persist 실패 시 4를
    /// 롤백하고 3에서 쓴 파일을 삭제한 뒤 오류를 던진다 — 재시작 후 다시 읽어도
    /// resultFile != nil인 항목은 파일이 실제로 존재하고, 고아 result 파일은 남지 않는다.
    /// entryID가 이미 지워진 항목이면 조용히 무시(호출부는 대부분 try?로 감싸므로,
    /// 여기서 예외를 던지면 이미 성공한 병합/복원을 실패처럼 보이게 한다).
    func recordResult(entryID: UUID, newBody: String) throws {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let original = entries[idx]
        let stamp = Self.timestampFormatter.string(from: Date())
        let base = original.pageURL.deletingPathExtension().lastPathComponent
        let file = backupsDir.appendingPathComponent("\(base)-\(stamp)-result.md").uniquified()
        do {
            try newBody.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        entries[idx] = WikiIngestLogEntry(
            id: original.id, pageURL: original.pageURL, backupFile: original.backupFile,
            resultFile: file.lastPathComponent, sourceName: original.sourceName, date: original.date)
        do {
            try persist()
        } catch {
            entries[idx] = original
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// 최신순 기록.
    func allEntries() -> [WikiIngestLogEntry] {
        Array(entries.reversed())
    }
    /// 이력 화면이 열릴 때 1회 호출 — 넘겨받은 항목들의 backupFile·resultFile 본문을
    /// 한 번에 읽어 [파일명: 본문] 맵으로 돌려준다(순수 `WikiHistoryGrouping`에 주입할
    /// 스냅샷 소스). 존재하지 않거나 못 읽는 파일은 맵에서 빠진다 — 호출부가
    /// `missingBackup`으로 해석한다.
    func snapshotBodies(for entries: [WikiIngestLogEntry]) -> [String: String] {
        var bodies: [String: String] = [:]
        for entry in entries {
            for name in [entry.backupFile, entry.resultFile].compactMap({ $0 }) {
                guard bodies[name] == nil else { continue }
                if let body = try? String(contentsOf: backupsDir.appendingPathComponent(name),
                                          encoding: .utf8) {
                    bodies[name] = body
                }
            }
        }
        return bodies
    }

    /// 복원 — 백업이 있으면 현재 본을 다시 백업(왕복 안전) 후 백업본으로 교체,
    /// 새 페이지(backupFile nil)면 생성 파일을 휴지통으로. 로그는 보존.
    /// 순서 고정: recordApply(before) → 파일 쓰기 → recordResult(after). 파일 쓰기가
    /// 실패하면 recordResult를 호출하지 않는다(그 "복원 전 자동 백업" 항목은 legacy로
    /// 남고 에러가 전파된다). recordResult만 실패하면 복원 자체는 성공이므로 try?로
    /// 삼키고 그 항목만 legacy로 남는다(적용·복원 두 경로 모두 동일 before/after 계약).
    func restore(_ entry: WikiIngestLogEntry) throws {
        if let backupFile = entry.backupFile {
            let backup = backupsDir.appendingPathComponent(backupFile)
            let restored = try String(contentsOf: backup, encoding: .utf8)
            let current = try? String(contentsOf: entry.pageURL, encoding: .utf8)
            var autoEntryID: UUID? = nil
            if let current {
                autoEntryID = try recordApply(pageURL: entry.pageURL, oldBody: current,
                                    sourceName: "복원 전 자동 백업").id
            }
            try restored.write(to: entry.pageURL, atomically: true, encoding: .utf8)
            if let autoEntryID {
                try? recordResult(entryID: autoEntryID, newBody: restored)
            }
        } else {
            _ = try FileOperations.trash(at: entry.pageURL)
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: logURL)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
