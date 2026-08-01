import Foundation
import SQLite3

/// 복습 대상 항목 하나(캐시 조회 결과, `study_items` 한 행, §3.8).
struct StudyIndexItem: Equatable {
    let uid: UUID
    let studyID: UUID
    let notePath: String
    let kind: StudyItemKind
    let loc: StudyLocator
    let title: String
    /// 제목 다음부터 다음 앵커 전까지 원문(§`StudyNoteParser.ParsedItem.body`) — 복습 화면 표시용.
    let body: String
    let state: StudyReviewState
    /// 마지막 재빌드(또는 채점 갱신) 시점의 앵커 원문 — 채점 직전 재확인(§3.6)용.
    let lineText: String
}

struct StudyIndexRebuildSummary: Equatable {
    let included: Int
    /// `item_uid` 중복(§3.6 승자 규칙)으로 걸러진 항목 수.
    let excluded: Int
}

/// 복습 캐시(`studyindex.sqlite`, §3.8). **진실의 출처가 아니라 재생성 가능한 파생 캐시**(§3.1)
/// — 삭제되거나 손상돼도 등록 폴더를 다시 훑으면(`rebuild`) 그대로 복구된다. 진짜 기록은
/// 항상 학습 노트 파일의 앵커 줄이다.
actor StudyIndex {
    private var db: OpaquePointer?
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(dbURL: URL) {
        var dbPtr: OpaquePointer?
        if sqlite3_open(dbURL.path, &dbPtr) != SQLITE_OK {
            sqlite3_close(dbPtr); dbPtr = nil
            try? FileManager.default.removeItem(at: dbURL)
            sqlite3_open(dbURL.path, &dbPtr)
        }
        db = dbPtr
        let schema = """
        CREATE TABLE IF NOT EXISTS study_items(
          item_uid TEXT PRIMARY KEY, study_id TEXT NOT NULL, note_path TEXT NOT NULL,
          kind TEXT NOT NULL, loc TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, line_text TEXT NOT NULL,
          due REAL NOT NULL, ivl INTEGER NOT NULL, ease REAL NOT NULL,
          reps INTEGER NOT NULL, lapses INTEGER NOT NULL, scanned_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_study_items_due ON study_items(due);
        CREATE INDEX IF NOT EXISTS idx_study_items_study_id ON study_items(study_id);
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            // 스키마 깨짐 → DB 재생성 후 1회 재시도(전례: `SearchIndex`).
            sqlite3_close(db); db = nil
            try? FileManager.default.removeItem(at: dbURL)
            sqlite3_open(dbURL.path, &db)
            sqlite3_exec(db, schema, nil, nil, nil)
        }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    // MARK: - 재빌드(§3.7)

    /// 등록 폴더를 전부 훑어 캐시를 통째로 다시 만든다. `.md`만 · 깊이 ≤ 8 · 심볼릭 링크
    /// 미추적 · 숨김 폴더 제외 · 전체 상한 20,000 · frontmatter에 `study_id`가 있고 항목이
    /// 1개 이상인 파일만(카드/문제). 대화 노트(`study_kind: chat`)는 항목이 없어 자동 제외.
    func rebuild(folders: [URL], now: Date = Date()) -> StudyIndexRebuildSummary {
        struct Candidate { let item: StudyIndexItem; let mtime: Double; let normalizedPath: String }
        var winners: [UUID: Candidate] = [:]
        var excluded = 0
        var scannedFiles = 0
        let fm = FileManager.default

        for folder in folders {
            guard scannedFiles < 20_000 else { break }
            let rootDepth = folder.standardizedFileURL.pathComponents.count
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard scannedFiles < 20_000 else { break }
                let standardized = url.standardizedFileURL
                let depth = standardized.pathComponents.count - rootDepth
                let values = try? standardized.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if depth > 8 {
                    if values?.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if values?.isDirectory == true { continue }
                guard standardized.pathExtension.lowercased() == "md" else { continue }
                scannedFiles += 1
                guard let content = try? String(contentsOf: standardized, encoding: .utf8) else { continue }
                let parsed = StudyNoteParser.parse(content)
                guard let studyID = parsed.studyID, let kind = parsed.kind, !parsed.items.isEmpty else { continue }
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let normalizedPath = standardized.path

                for item in parsed.items {
                    let candidate = Candidate(
                        item: StudyIndexItem(uid: item.uid, studyID: studyID, notePath: standardized.path, kind: kind,
                                              loc: item.loc, title: item.title, body: item.body, state: item.state,
                                              lineText: item.lineText),
                        mtime: mtime, normalizedPath: normalizedPath)
                    if let existing = winners[item.uid] {
                        // §3.6: mtime 최신 승자, 동일하면 정규화 절대경로 오름차순(POSIX) 승자.
                        let existingWins = existing.mtime > candidate.mtime
                            || (existing.mtime == candidate.mtime && existing.normalizedPath <= candidate.normalizedPath)
                        winners[item.uid] = existingWins ? existing : candidate
                        excluded += 1
                    } else {
                        winners[item.uid] = candidate
                    }
                }
            }
        }

        exec("BEGIN;")
        exec("DELETE FROM study_items;")
        for candidate in winners.values {
            insert(candidate.item, scannedAt: now.timeIntervalSince1970)
        }
        exec("COMMIT;")
        return StudyIndexRebuildSummary(included: winners.count, excluded: excluded)
    }

    private func insert(_ item: StudyIndexItem, scannedAt: Double) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT OR REPLACE INTO study_items
        (item_uid, study_id, note_path, kind, loc, title, body, line_text, due, ivl, ease, reps, lapses, scanned_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, item.uid.uuidString, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, item.studyID.uuidString, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 3, item.notePath, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 4, item.kind.rawValue, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 5, StudyNoteWriter.anchorLoc(item.loc), -1, TRANSIENT)
        sqlite3_bind_text(stmt, 6, item.title, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 7, item.body, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 8, item.lineText, -1, TRANSIENT)
        sqlite3_bind_double(stmt, 9, item.state.due.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 10, Int32(item.state.interval))
        sqlite3_bind_double(stmt, 11, item.state.ease)
        sqlite3_bind_int(stmt, 12, Int32(item.state.reps))
        sqlite3_bind_int(stmt, 13, Int32(item.state.lapses))
        sqlite3_bind_double(stmt, 14, scannedAt)
        sqlite3_step(stmt)
    }

    // MARK: - 조회(AC #14)

    /// 오늘 복습 대상(§3.9 하루 상한 적용 후). 새 항목(`reps==0 && lapses==0`)과 이미 한 번이라도
    /// 채점된 항목을 각각 캡핑해 기한 오름차순으로 합친다.
    func dueItems(today: Date = Date(), newLimit: Int = ReviewScheduler.dailyNewLimit,
                  reviewLimit: Int = ReviewScheduler.dailyReviewLimit) -> [StudyIndexItem] {
        let cutoff = Calendar.current.startOfDay(for: today).addingTimeInterval(86_400).timeIntervalSince1970
        let newItems = queryDue(before: cutoff, onlyNew: true, limit: newLimit)
        let reviewItems = queryDue(before: cutoff, onlyNew: false, limit: reviewLimit)
        return (newItems + reviewItems).sorted { $0.state.due < $1.state.due }
    }

    private func queryDue(before cutoff: Double, onlyNew: Bool, limit: Int) -> [StudyIndexItem] {
        let newFilter = onlyNew ? "AND reps = 0 AND lapses = 0" : "AND NOT (reps = 0 AND lapses = 0)"
        let sql = "SELECT item_uid, study_id, note_path, kind, loc, title, body, line_text, due, ivl, ease, reps, lapses "
            + "FROM study_items WHERE due < ? \(newFilter) ORDER BY due ASC LIMIT ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [StudyIndexItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uidC = sqlite3_column_text(stmt, 0), let uid = UUID(uuidString: String(cString: uidC)),
                  let studyIDC = sqlite3_column_text(stmt, 1), let studyID = UUID(uuidString: String(cString: studyIDC)),
                  let pathC = sqlite3_column_text(stmt, 2),
                  let kindC = sqlite3_column_text(stmt, 3), let kind = StudyItemKind(rawValue: String(cString: kindC)),
                  let locC = sqlite3_column_text(stmt, 4), let loc = StudyNoteWriter.parseAnchorLoc(String(cString: locC)),
                  let titleC = sqlite3_column_text(stmt, 5),
                  let bodyC = sqlite3_column_text(stmt, 6),
                  let lineC = sqlite3_column_text(stmt, 7)
            else { continue }
            let state = StudyReviewState(
                due: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                interval: Int(sqlite3_column_int(stmt, 9)), ease: sqlite3_column_double(stmt, 10),
                reps: Int(sqlite3_column_int(stmt, 11)), lapses: Int(sqlite3_column_int(stmt, 12)))
            out.append(StudyIndexItem(uid: uid, studyID: studyID, notePath: String(cString: pathC), kind: kind,
                                       loc: loc, title: String(cString: titleC), body: String(cString: bodyC),
                                       state: state, lineText: String(cString: lineC)))
        }
        return out
    }

    /// 채점 성공 직후 캐시 한 행만 갱신(파일에 이미 쓴 값과 정합) — 다음 재빌드 전까지 화면이
    /// 최신 상태를 반영하게 한다. 실패해도 조용히 무시(다음 재빌드가 바로잡는다, 캐시는 파생값).
    func updateAfterGrading(itemUID: UUID, newState: StudyReviewState, newLineText: String, now: Date = Date()) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "UPDATE study_items SET due=?, ivl=?, ease=?, reps=?, lapses=?, line_text=?, scanned_at=? WHERE item_uid=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, newState.due.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(newState.interval))
        sqlite3_bind_double(stmt, 3, newState.ease)
        sqlite3_bind_int(stmt, 4, Int32(newState.reps))
        sqlite3_bind_int(stmt, 5, Int32(newState.lapses))
        sqlite3_bind_text(stmt, 6, newLineText, -1, TRANSIENT)
        sqlite3_bind_double(stmt, 7, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 8, itemUID.uuidString, -1, TRANSIENT)
        sqlite3_step(stmt)
    }

    func count() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM study_items;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }
}
