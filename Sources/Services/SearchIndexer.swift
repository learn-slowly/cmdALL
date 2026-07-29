import Foundation

/// 폴더를 워킹하며 변경분만 (재)인덱싱하고 사라진 파일을 인덱스에서 제거한다.
/// 인덱싱은 읽기 전용 — 원본 파일을 건드리지 않는다.
actor SearchIndexer {
    private let index: SearchIndex
    private let kordoc: KordocService

    init(index: SearchIndex, kordoc: KordocService) {
        self.index = index
        self.kordoc = kordoc
    }

    /// URL을 정규 경로로 변환한다(예: /var → /private/var).
    /// 파일이 없으면 부모 디렉터리를 기준으로 해소한다.
    /// Task 6(AppState 배선)에서 등록 폴더 경로를 동일 방식으로 정규화할 수 있도록 static으로 공개.
    static func canonicalURL(_ url: URL) -> URL {
        // 존재하는 경우 직접 canonicalPath를 얻는다.
        if let c = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: c, isDirectory: false)
        }
        // 삭제된 파일처럼 존재하지 않는 경우 부모 기준으로 해소한다.
        let parent = url.deletingLastPathComponent()
        if let pc = try? parent.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: pc, isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
        }
        return url  // 폴백: 원본 그대로
    }

    /// 실제 문서가 아니라 개발 도구가 만든 부속 폴더 — 색인 대상에서 통째로 건너뛴다
    /// (2026-07-28 실사용 발견: 홈 폴더처럼 큰 폴더를 고르면 이런 부스러기 수만 개가
    /// 실제 문서보다 먼저 훑여 정작 필요한 폴더에 색인이 며칠이 지나도 못 닿았다).
    private static let excludedDirectoryNames: Set<String> = [
        "node_modules", "venv", ".venv", "__pycache__", "site-packages",
        "Pods", "DerivedData", ".build", ".git", ".svn", ".tox",
    ]

    func indexFolder(_ folder: URL, ocrScannedPDFs: Bool = false, ocrImages: Bool = false, progress: ((Int, Int) -> Void)?) async {
        // 폴더의 정규 경로를 구한다. enumerator도 동일 정규 경로를 반환하므로
        // indexedPaths prefix와 일치한다.
        let canonicalFolder = Self.canonicalURL(folder)
        let fm = FileManager.default
        // `.skipsHiddenFiles`만으로는 숨김 폴더(.build 등)가 실제로 안 걸러지는
        // 경우를 실사용에서 확인해(예: .build 안 208개 파일이 색인됨) 옵션에
        // 기대지 않고 직접 훑으며 이름·심볼릭 링크 여부를 판정한다.
        guard let en = fm.enumerator(at: canonicalFolder,
                                     includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
                                     options: [.skipsPackageDescendants]) else { return }
        // 조각 A(QuickLook fallback)로 isListableInFileTree가 확장자 무관 항상 true가
        // 되면서, 폴더 자신도(기존엔 확장자 불일치로 우연히 걸러졌다) 통과해 문서처럼
        // 색인되는 결함이 생겼다 — 실제 파일만(.isRegularFileKey) 남긴다.
        let rootPrefix = canonicalFolder.path.hasSuffix("/") ? canonicalFolder.path : canonicalFolder.path + "/"
        var urls: [URL] = []
        // async 함수 안에서 NSEnumerator를 `for...in`(Sequence)으로 훑으면
        // makeIterator가 비동기 컨텍스트에서 못 쓴다는 경고(Swift 6에서는 에러)가
        // 난다 — `nextObject()`를 직접 부르는 방식으로 우회.
        while let url = en.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                // 숨김 폴더(.으로 시작)·개발 부스러기 폴더는 안으로 들어가지 않는다.
                if name.hasPrefix(".") || Self.excludedDirectoryNames.contains(name) {
                    en.skipDescendants()
                    continue
                }
                // 지름길(symlink)이 고른 폴더 밖을 가리키면 따라가지 않는다
                // (실사용에서 /Library/Developer/... 시스템 폴더로 새는 사례 확인).
                let resolved = Self.canonicalURL(url).path
                if resolved != canonicalFolder.path && !resolved.hasPrefix(rootPrefix) {
                    en.skipDescendants()
                }
                continue
            }
            if values?.isRegularFile == true, !name.hasPrefix(".") {
                urls.append(url)
            }
        }
        urls = urls.filter { AppState.isListableInFileTree($0) }
        let total = urls.count
        var done = 0
        var seen = Set<String>()
        for url in urls {
            seen.insert(url.path)
            let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()).timeIntervalSince1970
            if await index.needsIndex(path: url.path, mtime: mtime) {
                let body = await ContentExtractor.body(for: url, kordoc: kordoc, ocrScannedPDFs: ocrScannedPDFs, ocrImages: ocrImages) ?? ""
                await index.upsert(path: url.path, filename: url.lastPathComponent,
                                   body: body, mtime: mtime, ext: url.pathExtension.lowercased())
            }
            done += 1
            progress?(done, total)
        }
        // 인덱스에는 있으나 디스크에서 사라진 파일 제거.
        for indexed in await index.indexedPaths(under: canonicalFolder.path) where !seen.contains(indexed) {
            await index.remove(path: indexed)
        }
    }

    /// 단일 경로 (재)인덱싱. 파일이 없으면 인덱스에서 제거.
    func reindex(path: String, ocrScannedPDFs: Bool = false, ocrImages: Bool = false) async {
        // 정규 경로로 변환(예: /var → /private/var). 파일이 없어도 부모 기준 해소.
        let canonicalURL = Self.canonicalURL(URL(fileURLWithPath: path))
        let canonicalPath = canonicalURL.path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonicalPath, isDirectory: &isDir), !isDir.boolValue,
              AppState.isListableInFileTree(canonicalURL) else {
            await index.remove(path: canonicalPath)
            return
        }
        let mtime = ((try? canonicalURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()).timeIntervalSince1970
        guard await index.needsIndex(path: canonicalPath, mtime: mtime) else { return }
        let body = await ContentExtractor.body(for: canonicalURL, kordoc: kordoc, ocrScannedPDFs: ocrScannedPDFs, ocrImages: ocrImages) ?? ""
        await index.upsert(path: canonicalPath, filename: canonicalURL.lastPathComponent,
                           body: body, mtime: mtime, ext: canonicalURL.pathExtension.lowercased())
    }
}
