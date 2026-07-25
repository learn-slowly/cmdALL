import Foundation

/// 앱 번들을 제자리에서 교체한다(스펙 §5.2). 실패하면 기존 번들을 원복해
/// "앱이 사라지는" 상태를 만들지 않는다. 옛 번들은 지우지 않고 휴지통으로 보낸다.
enum BundleReplacer {

    static func replace(
        staged: URL,
        target: URL,
        fileManager: FileManager = .default,
        disposeBackup: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        let parent = target.deletingLastPathComponent()

        // 0) 사전 점검 — 쓸 수 없으면 아무것도 건드리지 않고 멈춘다.
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.noWritePermission(path: parent.path)
        }

        let backup = parent.appendingPathComponent(".cmdALL-backup-\(UUID().uuidString).app")

        // 1) 기존 → 백업. 여기서 실패하면 아무것도 바뀌지 않았다.
        do {
            try fileManager.moveItem(at: target, to: backup)
        } catch {
            throw UpdateInstallError.replaceFailed(error.localizedDescription)
        }

        // 2) 새 것 → 제자리. 실패하면 즉시 원복한다.
        do {
            try fileManager.moveItem(at: staged, to: target)
        } catch {
            let moveError = error.localizedDescription
            do {
                try fileManager.moveItem(at: backup, to: target)
            } catch {
                // 원복까지 실패 — 사용자가 Finder로 되돌릴 수 있게 경로를 알린다.
                throw UpdateInstallError.replaceFailedBackupLeft(backupPath: backup.path)
            }
            throw UpdateInstallError.replaceFailed(moveError)
        }

        // 3) 성공 — 옛 번들은 휴지통으로(삭제 금지 원칙).
        try? disposeBackup(backup)
    }
}
