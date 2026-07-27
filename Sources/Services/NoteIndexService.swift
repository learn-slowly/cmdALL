import Foundation

/// Builds the wiki-link completion index by scanning note roots for Markdown
/// files. Only file names are read — never contents — so even large vaults
/// index quickly. Runs off the main thread (see AppState.rebuildNoteIndex).
enum NoteIndexService {
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt"]

    /// - chunkSize: `onChunk`을 몇 개 모일 때마다 부를지(중간 진행 반영용).
    /// - onChunk: 지금까지 모은 걸 정렬해 전달(누적본 — 매번 전체를 다시 보내므로
    ///   호출 쪽은 그냥 덮어써도 된다). 취소는 호출 쪽이 `Task.isCancelled`로 판단.
    static func buildIndex(
        roots: [URL],
        limit: Int = 200_000,
        chunkSize: Int = 10_000,
        onChunk: (([VaultNote]) -> Void)? = nil
    ) -> [VaultNote] {
        var notes: [VaultNote] = []
        var seenPaths: Set<String> = []
        var lastChunkCount = 0

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                let standardized = fileURL.standardizedFileURL
                guard seenPaths.insert(standardized.path).inserted else { continue }

                let modified = (try? standardized.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast

                notes.append(VaultNote(
                    path: relativePath(of: standardized, in: root),
                    title: standardized.deletingPathExtension().lastPathComponent,
                    modifiedAt: modified,
                    url: standardized
                ))

                if notes.count - lastChunkCount >= chunkSize {
                    lastChunkCount = notes.count
                    onChunk?(sorted(notes))
                }

                if notes.count >= limit {
                    return sorted(notes)
                }
            }
        }

        return sorted(notes)
    }

    /// Recently-modified notes first so completions surface what the user is
    /// actually working with.
    private static func sorted(_ notes: [VaultNote]) -> [VaultNote] {
        notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func relativePath(of fileURL: URL, in root: URL) -> String {
        let rootPrefix = root.standardizedFileURL.path + "/"
        guard fileURL.path.hasPrefix(rootPrefix) else { return fileURL.lastPathComponent }
        return String(fileURL.path.dropFirst(rootPrefix.count))
    }
}
