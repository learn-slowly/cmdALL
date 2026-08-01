import Foundation
import AppKit
import UniformTypeIdentifiers
import WebKit
import PDFKit
import Quartz

extension AppState {

    // MARK: - 파일 작업 (F1a — 이름변경·휴지통·되돌리기)

    /// 짝꿍 노트 동반 대상 — url이 미디어 파일이고 노트(파일명.ext.md)가 실재할 때만.
    static func companionNoteForOperation(mediaURL: URL) -> URL? {
        guard DocumentKind(from: mediaURL) == .media else { return nil }
        let note = CompanionNote.noteURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: note.path) else { return nil }
        return note
    }

    /// 짝꿍 노트 frontmatter의 `media:` 필드를 실제 미디어 파일명에 맞춘다(정합 유지).
    /// 읽기·교체 실패와 변경 불필요는 조용히 넘어간다 — 본체 작업(rename/이동/복사/undo)의
    /// 성패와 무관한 부수 정합이고, 필드가 옛 이름이어도 기능엔 지장 없다(코스메틱).
    static func syncCompanionMediaField(note: URL, mediaFileName: String) {
        guard let content = try? String(contentsOf: note, encoding: .utf8),
              let updated = CompanionNote.updatingMediaField(in: content, to: mediaFileName)
        else { return }
        try? updated.write(to: note, atomically: true, encoding: .utf8)
    }

    /// 복원(undo)된 경로 기준으로 미디어↔짝꿍 노트 쌍이 완성돼 있으면 media: 필드를 정합.
    /// 미디어·노트 엔트리 어느 쪽이 나중에 복원되든(개별 undo 순서 무관) 쌍이 완성된
    /// 시점의 호출이 잡는다 — 양방향 검사·멱등. 짝꿍 판별은 확장자 기반이라 미디어 확장자
    /// 이름의 '폴더'도 미디어로 오인한다 — forward 경로의 isDirectory 가드와 대칭으로
    /// 복원 대상·대응 미디어 둘 다 디렉터리를 배제한다(무관 수기 노트 변조 방지).
    static func syncCompanionPairAfterRestore(_ restoredURL: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: restoredURL.path, isDirectory: &isDir),
              !isDir.boolValue else { return }
        if let note = companionNoteForOperation(mediaURL: restoredURL) {
            syncCompanionMediaField(note: note, mediaFileName: restoredURL.lastPathComponent)
        } else if let media = CompanionNote.mediaURL(for: restoredURL),
                  FileManager.default.fileExists(atPath: media.path, isDirectory: &isDir),
                  !isDir.boolValue {
            syncCompanionMediaField(note: restoredURL, mediaFileName: media.lastPathComponent)
        }
    }

    /// 이름 변경 + 로그 + 열린 탭·짝꿍 노트 정합. 성공 시 새 URL 반환.
    /// 검증 실패는 FileOperationError로 던진다 — 시트가 인라인 표시(전역 errorMessage 미사용).
    @discardableResult
    func performRename(at url: URL, to newName: String) async throws -> URL {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        // 짝꿍 노트가 있으면 rename 전에 편집 중이던 버퍼를 노트에 flush(동기 게시). 안 그러면
        // 옛 뷰의 stale onDisappear가 이미 옮겨진 옛 경로에 써서 고아 노트를 부활시킨다.
        if companion != nil {
            NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
        }

        let newURL = try FileOperations.rename(at: url, to: newName)
        await fileOpsLogStore.append(FileOpEntry(kind: .rename, originalURL: url, resultURL: newURL))
        retargetOpenTabs(from: url, to: newURL, isDirectory: isDirectory)

        // 짝꿍 노트 동반 rename(파일명.ext.md 규칙 유지). 실패해도 본체 rename은 유지 — 토스트로 알림.
        if let companion {
            let newNoteName = CompanionNote.noteURL(for: newURL).lastPathComponent
            do {
                let movedNote = try FileOperations.rename(at: companion, to: newNoteName)
                // frontmatter media: 정합 — 다음 suspension(로그 append) 전에 동기로 마쳐야
                // 재조준된 미디어 뷰의 재로드(.task(id: url))가 항상 갱신본을 읽는다.
                Self.syncCompanionMediaField(note: movedNote, mediaFileName: newURL.lastPathComponent)
                await fileOpsLogStore.append(
                    FileOpEntry(kind: .rename, originalURL: companion, resultURL: movedNote))
                retargetOpenTabs(from: companion, to: movedNote, isDirectory: false)
            } catch {
                showToast("짝꿍 노트 이름은 바꾸지 못했습니다")
            }
        }

        completeFileOperation()
        return newURL
    }

    /// 휴지통 확인 대화상자(제안→확인→실행) — 확인 시 performTrash. NSAlert 관례는 closeAllTabs와 동일.
    func trashWithConfirmation(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        let alert = NSAlert()
        alert.messageText = "'\(url.lastPathComponent)'을(를) 휴지통으로 이동할까요?"
        var info = "휴지통에서 복구할 수 있고, '파일 작업 기록'에서 되돌릴 수 있습니다."
        if let companion {
            info = "짝꿍 메모('\(companion.lastPathComponent)')도 함께 이동합니다. " + info
        }
        if hasDirtyTab(under: url, isDirectory: isDirectory) {
            info = "저장 안 된 변경이 있는 탭이 닫힙니다. " + info
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await performTrash(at: url) }
    }

    /// 휴지통 이동 + 로그 + 관련 탭 닫기(+짝꿍 노트 동반). 확인은 trashWithConfirmation 몫.
    @discardableResult
    func performTrash(at url: URL) async -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        // 짝꿍 노트가 있으면 탭을 닫기 전에 편집 중이던 버퍼를 flush(동기 게시) — 그래야 최신
        // 편집이 노트와 함께 휴지통으로 가고(복구 가능), 탭 닫기 onDisappear의 stale write로
        // 고아 노트가 부활하지 않는다.
        if companion != nil {
            NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
        }

        // 대상(하위 포함)·짝꿍 노트를 보는 탭 먼저 닫는다 — 워처·플레이어 정리는 closeTab이 담당.
        closeTabs(under: url, isDirectory: isDirectory)
        if let companion { closeTabs(under: companion, isDirectory: false) }

        do {
            let trashedURL = try FileOperations.trash(at: url)
            await fileOpsLogStore.append(
                FileOpEntry(kind: .trash, originalURL: url, resultURL: trashedURL))
            if let companion {
                do {
                    let trashedNote = try FileOperations.trash(at: companion)
                    await fileOpsLogStore.append(
                        FileOpEntry(kind: .trash, originalURL: companion, resultURL: trashedNote))
                } catch {
                    showToast("짝꿍 노트는 휴지통으로 옮기지 못했습니다")
                }
            }
            completeFileOperation()
            return true
        } catch {
            errorMessage = (error as? FileOperationError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    /// 파일 작업 되돌리기 — 성공 시 갱신 트리거까지.
    func undoFileOp(_ entry: FileOpEntry) async -> Bool {
        // copy 되돌리기 = 사본이 휴지통으로 감 — 사본을 보던 탭 먼저 닫는다.
        if entry.kind == .copy {
            closeTabs(under: entry.resultURL, isDirectory: isDirectoryPath(entry.resultURL))
        }
        let ok = await fileOpsLogStore.undo(entry)
        if ok {
            // rename/move 되돌리기 = 파일이 resultURL → originalURL로 복귀. 그 경로를 보던
            // 탭도 재조준 — 안 그러면 워처가 "외부에서 삭제됨"으로 오인해 fileURL을 분리하고,
            // 미디어 탭이면 뷰가 사라져도 플레이어가 레지스트리에 남아 재생이 이어진다.
            // trash 되돌리기는 대상 탭이 이미 닫혀 있어(performTrash의 closeTabs) 재조준할 탭이 없다.
            if entry.kind == .rename || entry.kind == .move {
                let isDirectory = (try? entry.originalURL
                    .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                retargetOpenTabs(from: entry.resultURL, to: entry.originalURL, isDirectory: isDirectory)
                // 복원으로 미디어↔짝꿍 노트 쌍이 다시 완성되면 frontmatter media: 도 원복.
                // 쌍의 두 엔트리는 개별 undo라 순서를 모른다 — 나중에 복원되는 쪽이 잡는다.
                Self.syncCompanionPairAfterRestore(entry.originalURL)
            }
            completeFileOperation()
        }
        return ok
    }

    // MARK: - 배치 파일 작업 (F1b)

    /// 배치 요약 확인(제안→확인→실행) — 항목별 모달 N회 금지, 요약 1회(Close All Tabs 관례).
    /// 단건이면 기존 trashWithConfirmation 재사용(문구 동일성).
    func batchTrashWithConfirmation(_ urls: [URL]) {
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        guard !targets.isEmpty else { return }
        if targets.count == 1 { trashWithConfirmation(targets[0]); return }

        let alert = NSAlert()
        alert.messageText = "\(targets.count)개 항목을 휴지통으로 이동할까요?"
        var info = "휴지통에서 복구할 수 있고, '파일 작업 기록'에서 한 번에 되돌릴 수 있습니다."
        if targets.contains(where: { Self.companionNoteForOperation(mediaURL: $0) != nil }) {
            info = "짝꿍 메모도 함께 이동합니다. " + info
        }
        if targets.contains(where: { hasDirtyTab(under: $0, isDirectory: isDirectoryPath($0)) }) {
            info = "저장 안 된 변경이 있는 탭이 닫힙니다. " + info
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await self.performBatchTrash(urls: targets) }
    }

    /// 배치 휴지통 — 건별(flush→탭 선닫기→trash→엔트리 수집) 후 로그·갱신은 배치 끝 1회.
    /// 부분 실패는 계속 진행 + 요약. 확인은 batchTrashWithConfirmation 몫.
    @discardableResult
    func performBatchTrash(urls: [URL]) async -> (succeeded: Int, failed: Int) {
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()   // 동반 처리된 짝꿍 노트(standardized path) — 이중 처리 방지

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            closeTabs(under: url, isDirectory: isDirectory)
            if let companion { closeTabs(under: companion, isDirectory: false) }
            do {
                let trashed = try FileOperations.trash(at: url)
                entries.append(FileOpEntry(kind: .trash, originalURL: url,
                                           resultURL: trashed, batchId: batchId))
                if let companion {
                    do {
                        let trashedNote = try FileOperations.trash(at: companion)
                        entries.append(FileOpEntry(kind: .trash, originalURL: companion,
                                                   resultURL: trashedNote, batchId: batchId))
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "휴지통 이동")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    /// "폴더로 이동…" — NSOpenPanel(디렉터리 선택)이 확인 역할. urls nil이면 현재 선택.
    func promptBatchMove(urls: [URL]? = nil) {
        let targets = urls ?? Array(fileSelection)
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "이동"
        panel.message = "\(targets.count)개 항목을 이동할 폴더를 선택하세요"
        panel.directoryURL = selectedFolder ?? currentFolder
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in await self.performBatchMove(urls: targets, to: destination) }
    }

    /// 배치 이동 — 건별(flush→move→탭 재조준→짝꿍 동반) 후 로그·갱신은 배치 끝 1회.
    /// 이미 목적지에 있는 항목은 skip(실패 아님 — 제자리 이동은 uniquify가 복제 개명으로 둔갑).
    @discardableResult
    func performBatchMove(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int) {
        let destStd = destinationDir.standardizedFileURL
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls)).filter {
            $0.standardizedFileURL.deletingLastPathComponent().path != destStd.path
        }
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            do {
                let moved = try FileOperations.move(at: url, to: destStd)
                entries.append(FileOpEntry(kind: .move, originalURL: url,
                                           resultURL: moved, batchId: batchId))
                retargetOpenTabs(from: url, to: moved, isDirectory: isDirectory)
                if let companion {
                    do {
                        let finalNote = try relocateCompanion(companion, mode: .move,
                                                              to: destStd, alongside: moved,
                                                              failures: &failures)
                        // 본체가 uniquify로 개명됐으면 frontmatter media: 도 맞춘다(무변경이면 no-op).
                        Self.syncCompanionMediaField(note: finalNote,
                                                     mediaFileName: moved.lastPathComponent)
                        entries.append(FileOpEntry(kind: .move, originalURL: companion,
                                                   resultURL: finalNote, batchId: batchId))
                        retargetOpenTabs(from: companion, to: finalNote, isDirectory: false)
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "이동")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    /// 배치 복사 — 원본·탭 불변, 로그만(undo=사본 휴지통). 같은 폴더 복사 = 사본 시맨틱.
    @discardableResult
    func performBatchCopy(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int) {
        let destStd = destinationDir.standardizedFileURL
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                // 편집 중 버퍼를 원본 노트에 flush — 사본에 최신 내용이 담기게.
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            do {
                let copied = try FileOperations.copy(at: url, to: destStd)
                entries.append(FileOpEntry(kind: .copy, originalURL: url,
                                           resultURL: copied, batchId: batchId))
                if let companion {
                    do {
                        let finalNote = try relocateCompanion(companion, mode: .copy,
                                                              to: destStd, alongside: copied,
                                                              failures: &failures)
                        // 사본 노트만 사본 이름으로 정합 — 원본 노트는 불변(무변경이면 no-op).
                        Self.syncCompanionMediaField(note: finalNote,
                                                     mediaFileName: copied.lastPathComponent)
                        entries.append(FileOpEntry(kind: .copy, originalURL: companion,
                                                   resultURL: finalNote, batchId: batchId))
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "복사")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    enum CompanionRelocateMode { case move, copy }

    /// 짝꿍 노트 동반 이동/복사 — 결과 이름은 본체 결과에서 파생(파일명.ext.md 규칙 유지).
    /// 본체가 uniquify로 개명됐으면(노래.mp3→노래 (1).mp3) 노트도 "노래 (1).mp3.md"로 맞춘다.
    /// 파생 이름이 점유돼 있으면 노트만 uniquify하고 연결 끊김을 failures에 기록(스펙 §4.3).
    func relocateCompanion(_ companion: URL, mode: CompanionRelocateMode,
                                   to destinationDir: URL, alongside movedBody: URL,
                                   failures: inout [String]) throws -> URL {
        let relocated: URL
        switch mode {
        case .move: relocated = try FileOperations.move(at: companion, to: destinationDir)
        case .copy: relocated = try FileOperations.copy(at: companion, to: destinationDir)
        }
        let desiredName = CompanionNote.noteURL(for: movedBody).lastPathComponent
        guard relocated.lastPathComponent != desiredName else { return relocated }
        if let aligned = try? FileOperations.rename(at: relocated, to: desiredName) {
            return aligned
        }
        failures.append("짝꿍 노트 이름 정렬: \(relocated.lastPathComponent)")
        return relocated
    }

    /// 부분 실패 요약 — errorMessage는 단일 문자열이라 건별 나열 대신 개수+예시.
    func reportBatchFailures(_ failures: [String], action: String) {
        guard !failures.isEmpty else { return }
        let sample = failures.prefix(3).joined(separator: ", ")
        errorMessage = "\(action) 중 \(failures.count)건을 처리하지 못했습니다: \(sample)"
    }

    /// 배치 되돌리기 — copy 사본 탭 선닫기 → 스토어 역순 undo → move/rename 성공분 탭 재조준.
    func undoFileOpBatch(batchId: UUID) async -> Bool {
        let entries = await fileOpsLogStore.load().filter { $0.batchId == batchId }
        for entry in entries where entry.kind == .copy {
            closeTabs(under: entry.resultURL, isDirectory: isDirectoryPath(entry.resultURL))
        }
        let result = await fileOpsLogStore.undoBatch(batchId: batchId)
        for entry in result.succeeded where entry.kind == .rename || entry.kind == .move {
            // 복원 = resultURL → originalURL. 그 경로를 보던 탭 재조준(F1a undo 함정의 동형 방지).
            retargetOpenTabs(from: entry.resultURL, to: entry.originalURL,
                             isDirectory: isDirectoryPath(entry.originalURL))
            // 이 루프는 전체 복원 뒤에 돌므로 미디어·노트 어느 엔트리든 쌍 완성 상태에서 정합된다.
            Self.syncCompanionPairAfterRestore(entry.originalURL)
        }
        completeFileOperation()
        return result.failed.isEmpty
    }

    /// 현재 컨텍스트의 정보 보기 대상 — 리더=활성 탭 파일(없으면 무동작),
    /// 라이브러리=표시 중 폴더(selectedFolder ?? currentFolder). 스펙 §7.2.
    func showFileInfoForCurrentContext() {
        switch mainMode {
        case .reader:
            guard let url = activeTab?.fileURL else { return }
            fileInfoRequest = FileInfoRequest(url: url)
        case .library:
            guard let folder = selectedFolder ?? currentFolder else { return }
            fileInfoRequest = FileInfoRequest(url: folder)
        case .tasks:
            // 할일 모드에는 정보를 볼 파일·폴더 대상이 없다 — 무동작.
            return
        }
    }

    // MARK: - 페이스트보드·키 액션 (F1b)

    /// 선택 항목을 페이스트보드로(⌘C) — Finder에 붙여넣기 가능. 빈 선택이면 false(이벤트 미소비).
    @discardableResult
    func copySelectionToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard !fileSelection.isEmpty else { return false }
        FilePasteboard.write(FileSelectionHelper.ancestorsOnly(fileSelection), to: pasteboard)
        return true
    }

    /// 페이스트보드 파일을 폴더에 복사/이동 실행(⌘V/⌥⌘V) — folder nil이면 표시 폴더.
    func pasteFromPasteboard(move: Bool, into folder: URL? = nil,
                             pasteboard: NSPasteboard = .general) {
        guard let destination = folder ?? selectedFolder ?? currentFolder else { return }
        let urls = FilePasteboard.readFileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            if move {
                await self.performBatchMove(urls: urls, to: destination)
            } else {
                await self.performBatchCopy(urls: urls, to: destination)
            }
        }
    }

    // MARK: - 드래그&드롭 (F2)

    /// 드롭 수행 — providers에서 URL 수집 후 배치 1회 호출(이동 기본·⌥=복사).
    /// 무확인 실행(⌘V 선례 — 드롭 제스처가 곧 확인, 배치 undo 있음). 반환 = 수락 여부.
    /// ⚠️ F1b 붙여넣기(⌘V=복사·⌥⌘V=이동)와 ⌥ 의미가 역방향 — 둘 다 Finder 관례 준수(스펙 §0).
    @discardableResult
    func handleFileDrop(_ providers: [NSItemProvider], into destination: URL,
                        pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        // ⌥는 드롭 콜백 진입 직후 동기로 판독(비동기 수집 후엔 이미 떼었을 수 있음).
        let isCopy = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
        if DragPayload.isInternalDrag(pasteboard: pasteboard) {
            // 내부 드래그 — 페이로드는 드래그 시작 스냅샷(draggingURLs)이 유일한 채널.
            // 실측(2층): ①SwiftUI .onDrag 전사가 드롭 쪽 provider 재구성에서 커스텀 UTType을
            // 누락하고, ②드래그 파스테보드에 실려도 커스텀 타입 데이터 promise는 이행되지 않는다
            // (0바이트). 판별은 파스테보드의 타입 '선언'으로 하되, 전체 목록은 앱 내부 상태로 나른다.
            // 외부 세션은 선언이 없어 이 분기에 못 들어옴 → stale 스냅샷 미참조(C1 불변식 유지).
            completeFileDrop(draggingURLs, into: destination, isCopy: isCopy)
            return true
        }
        Self.collectDropURLs(providers) { [weak self] urls in
            self?.completeFileDrop(urls, into: destination, isCopy: isCopy)
        }
        return true
    }

    /// 드롭 다운스트림 공유 — 내부(동기 스냅샷)·외부(비동기 수집) 공통: draggingURLs 비우기 →
    /// 2차 필터(자기/하위 제거) → 배치 1회(이동/⌥복사) → 전량 same-parent skip 시 토스트.
    func completeFileDrop(_ urls: [URL], into destination: URL, isCopy: Bool) {
        Task { @MainActor in
            self.draggingURLs = []
            // 2차 방어 — 뷰 사전 차단(1차)이 못 거른 경로(배경 타깃 등) 대비.
            let targets = urls.filter { DropGuard.canAccept(source: $0, destination: destination) }
            guard !targets.isEmpty else { return }
            if isCopy {
                await self.performBatchCopy(urls: targets, to: destination)
            } else {
                let result = await self.performBatchMove(urls: targets, to: destination)
                // 전량 same-parent skip → (0,0): 무동작 오인 방지 토스트(이동만 — 복사는
                // 같은 폴더도 uniquify 사본 생성이 정상, 스펙 §3).
                if result.succeeded == 0 && result.failed == 0 {
                    self.showToast("이동할 항목 없음 — 이미 이 폴더에 있습니다")
                }
            }
        }
    }

    /// providers → fileURL 수집(외부 Finder 드래그 전용). 내부 드래그는 handleFileDrop이
    /// draggingURLs 스냅샷으로 직접 처리해 이 경로에 오지 않는다(파스테보드/​provider 어느 쪽도
    /// 커스텀 페이로드 데이터를 나르지 못하는 실측 — DragPayload.isInternalDrag 주석 참조).
    /// 반환 순서 = provider 순서(인덱스 슬롯 — loadItem 콜백은 임의 스레드·임의 순서, 스펙 §2.3).
    static func collectDropURLs(_ providers: [NSItemProvider],
                                completion: @escaping ([URL]) -> Void) {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier("public.file-url")
        }
        var slots = [URL?](repeating: nil, count: fileProviders.count)
        let lock = NSLock()   // loadItem 콜백은 임의 스레드 — 슬롯 쓰기 직렬화
        let group = DispatchGroup()
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); slots[index] = url; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(slots.compactMap { $0 }) }
    }

    /// 리더·창 레벨 외부(Finder) 파일 드롭 = 열기. 직렬 큐로 수렴해 더블클릭과 시맨틱 통일 —
    /// 항상 새 탭, 다중은 provider 순서대로 열고 마지막 활성(스펙 §2.3).
    /// 개정(2026-07-06): F2의 "단일 드롭 = 활성 탭 교체"를 폐기 — 드롭 한 번에 작업 중이던
    /// 탭이 교체당하는 놀람 제거, 더블클릭·드롭 시맨틱 일치.
    func openExternalFileDrops(_ providers: [NSItemProvider]) {
        Self.collectDropURLs(providers) { [weak self] urls in
            self?.enqueueExternalOpen(urls)
        }
    }

    /// 라이브러리가 표시 중인 목록 전체 선택(⌘A) — 디스크 재열거가 아니라 화면에 보이는
    /// libraryOrderedURLs만 대상으로 한다(외부에서 추가된 미표시 파일이 선택에 새는 것 방지).
    func selectAllInLibrary() {
        fileSelection = Set(libraryOrderedURLs)
        selectionAnchor = libraryOrderedURLs.first
    }

    /// 키 이벤트의 문자 판독(입력 소스 독립) — 두벌식 한글 등 비ASCII 입력 소스에서는
    /// charactersIgnoringModifiers가 자모("ㅁ"/"ㅊ"/"ㅍ")로 와 문자 매칭이 전멸한다(실측).
    /// ASCII 단일 문자면 그대로 쓰고, 아니면 Cmd 적용 문자(입력기 우회 ASCII·⌥도 벗김)로
    /// 폴백한다. 둘 다 비ASCII면 원값 반환(비교 실패로 자연 무시).
    static func keyLetter(ignoringModifiers: String?, commandApplied: String?) -> String {
        let ign = (ignoringModifiers ?? "").lowercased()
        if ign.count == 1, let s = ign.unicodeScalars.first, s.isASCII { return ign }
        let cmd = (commandApplied ?? "").lowercased()
        if cmd.count == 1, let s = cmd.unicodeScalars.first, s.isASCII { return cmd }
        return ign
    }

    /// 파일 키(⌘C 등)를 양보해야 하는 응답자인가 — 자체 복사/편집을 가진 뷰들.
    /// NSText(에디터·필드 에디터) 외에 WKWebView(미리보기)·PDFView(PDF 리더)·
    /// QLPreviewView(애플 미리보기 — 조각 A)도 자체 복사/스크롤을 구현한다.
    /// 뷰 계층 상위에 있을 수 있어(웹뷰 내부 서브뷰가 firstResponder) 조상 체인을 걷는다.
    static func responderYieldsFileKeys(_ responder: NSResponder?) -> Bool {
        if responder is NSText { return true }   // NSTextView 포함(필드 에디터도)
        var view = responder as? NSView
        while let v = view {
            if v is WKWebView || v is PDFView || v is QLPreviewView { return true }
            view = v.superview
        }
        return false
    }

    /// F1b 파일 키 라우팅 — 로컬 NSEvent 모니터에서 호출. true = 소비(모니터가 nil 반환).
    /// 가드(스펙 §5): 메인 창(시트 아님) + firstResponder가 자체 복사/편집 뷰가 아님.
    func handleFileOpsKeyEvent(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.canBecomeMain else { return false }
        // NSText 외에 미리보기(WKWebView)·PDF(PDFView)도 자체 copy를 양보한다.
        if Self.responderYieldsFileKeys(window.firstResponder) { return false }

        // deviceIndependentFlagsMask는 capsLock 비트를 포함 — CapsLock ON이면 정확 일치가
        // 전부 실패한다. 우리가 관심 있는 수식키만 교집합으로 추린다.
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // 한글 입력 소스에서도 물리 키를 읽도록 입력 소스 독립 판독(keyLetter) 사용.
        let key = Self.keyLetter(ignoringModifiers: event.charactersIgnoringModifiers,
                                 commandApplied: event.characters(byApplyingModifiers: .command))

        // ⎋ 선택 해제
        if event.keyCode == 53, flags.isEmpty, !fileSelection.isEmpty {
            clearFileSelection()
            return true
        }
        // ⌘⌫ 휴지통(요약 확인 경유) — 이벤트 모니터 콜백 안에서 중첩 모달 루프(runModal)를
        // 돌리지 않도록 Task로 이연한다. 이벤트는 즉시 소비.
        if event.keyCode == 51, flags == .command, !fileSelection.isEmpty {
            let urls = Array(fileSelection)
            Task { @MainActor in self.batchTrashWithConfirmation(urls) }
            return true
        }
        switch (key, flags) {
        case ("c", [.command]):
            return copySelectionToPasteboard()
        case ("v", [.command]):
            guard mainMode == .library, !FilePasteboard.readFileURLs().isEmpty else { return false }
            pasteFromPasteboard(move: false)
            return true
        case ("v", [.command, .option]):
            guard mainMode == .library, !FilePasteboard.readFileURLs().isEmpty else { return false }
            pasteFromPasteboard(move: true)
            return true
        case ("a", [.command]):
            guard mainMode == .library else { return false }
            selectAllInLibrary()
            return true
        default:
            return false
        }
    }
    // MARK: - 스페이스바 빠른 보기(스펙 §5)

    /// 빠른 보기 후보 — 선택한 파일을 화면 표시 순서대로.
    /// 표시 목록(libraryOrderedURLs)을 진실원으로 삼는다(F1b ⌘A 관례 — 화면에
    /// 없는 파일이 선택에 새어 들어오는 것을 막는다).
    func quickLookCandidates() -> [URL] {
        guard !fileSelection.isEmpty else { return [] }
        let ordered = libraryOrderedURLs.filter { fileSelection.contains($0) }
        if !ordered.isEmpty { return ordered }
        // 트리 ⌘클릭처럼 표시 목록 밖에서 고른 경우 — 경로순으로 안정 정렬.
        return fileSelection.sorted { $0.path < $1.path }
    }

    func openQuickLook(urls: [URL]) {
        guard !urls.isEmpty else { return }
        quickLookURLs = urls
        quickLookIndex = 0
        isQuickLookPresented = true
    }

    func closeQuickLook() {
        isQuickLookPresented = false
        quickLookURLs = []
        quickLookIndex = 0
    }

    /// 좌우 이동 — 양끝에서 멈춘다(감싸지 않는다).
    func stepQuickLook(by delta: Int) {
        guard !quickLookURLs.isEmpty else { return }
        quickLookIndex = min(max(quickLookIndex + delta, 0), quickLookURLs.count - 1)
    }

    /// 빠른 보기 키 라우팅 — 로컬 NSEvent 모니터에서 **파일 키보다 먼저** 호출한다.
    /// true = 소비. 전역 .keyboardShortcut은 쓰지 않는다(F1b에서 확립된 규칙).
    func handleQuickLookKeyEvent(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.canBecomeMain else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags.isEmpty else { return false }

        // 떠 있을 때의 키는 먼저 처리한다 — 미리보기 부품이 먼저 먹지 않도록.
        if isQuickLookPresented {
            switch event.keyCode {
            case 49, 53:            // 스페이스 · ⎋
                closeQuickLook()
                return true
            case 123:               // ←
                stepQuickLook(by: -1)
                return true
            case 124:               // →
                stepQuickLook(by: 1)
                return true
            default:
                return false
            }
        }

        guard event.keyCode == 49 else { return false }   // 스페이스
        // 글자 입력칸·미리보기(WKWebView)·PDF가 활성이면 양보한다.
        // 스페이스는 띄어쓰기·스크롤에 쓰이므로 가로채면 즉시 치명적이다.
        if Self.responderYieldsFileKeys(window.firstResponder) { return false }

        let candidates = quickLookCandidates()
        guard !candidates.isEmpty else { return false }
        openQuickLook(urls: candidates)
        return true
    }

    // MARK: - 다중 선택 (F1b)

    /// 라이브러리 클릭 한 번 처리 — 리졸버(순수)에 위임. ordered = 화면 표시 순서(entries).
    func handleFileClick(_ url: URL, modifier: SelectionModifier, ordered: [URL]) {
        let result = FileSelectionHelper.resolve(current: fileSelection, anchor: selectionAnchor,
                                                 clicked: url, modifier: modifier, ordered: ordered)
        fileSelection = result.selection
        selectionAnchor = result.anchor
    }

    /// 트리 ⌘클릭 토글 — 범위 선택이 없어 ordered 불필요.
    func toggleFileSelection(_ url: URL) {
        handleFileClick(url, modifier: .command, ordered: [])
    }

    func clearFileSelection() {
        fileSelection = []
        selectionAnchor = nil
    }

    /// 파일 작업 후 사라진 URL을 선택에서 제거 — 유령 선택에 배치가 실행되는 것을 방지.
    func pruneFileSelection() {
        fileSelection = fileSelection.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let anchor = selectionAnchor, !FileManager.default.fileExists(atPath: anchor.path) {
            selectionAnchor = nil
        }
    }

    /// 파일 작업 성공 후 공통 갱신 — 세대 토큰·트리·세션·선택 prune·표시 폴더/히스토리 정합(F3).
    func completeFileOperation() {
        fileOpsGeneration += 1
        pruneFileSelection()
        retargetStaleSelectedFolder()
        retargetStalePanes()
        navHistory.prune(isValid: Self.folderExists)
        loadFileTree()
        saveSession()
    }

    /// rename된 경로를 보는 열린 탭들의 URL·제목·문서·파일워처를 새 경로로 옮긴다.
    /// 폴더 rename이면 하위 경로 탭 전부 — '/' 경계 prefix 비교(형제 폴더 오매칭 방지).
    func retargetOpenTabs(from oldURL: URL, to newURL: URL, isDirectory: Bool) {
        let oldPath = oldURL.standardizedFileURL.path
        for index in tabs.indices {
            guard let tabURL = tabs[index].fileURL else { continue }
            let tabPath = tabURL.standardizedFileURL.path
            let target: URL?
            if tabPath == oldPath {
                target = newURL
            } else if isDirectory, tabPath.hasPrefix(oldPath + "/") {
                target = newURL.appendingPathComponent(String(tabPath.dropFirst(oldPath.count + 1)))
            } else {
                target = nil
            }
            guard let target else { continue }
            let tab = tabs[index]
            tabs[index].fileURL = target
            // title 동기화 — EditorTab.displayTitle이 fileURL을 우선해 실제 표시엔
            // 영향이 적지만, 탭 생성부 관례(비마크다운 분기·saveDocumentAs)를 따라
            // 확장자 없는 이름으로 맞춘다.
            tabs[index].title = target.deletingPathExtension().lastPathComponent
            documents[tab.documentId]?.fileURL = target
            // 파일 워처 재장전 — 옛 경로 디스크립터를 닫고 새 경로로. 단, 원래 워처가 있던
            // 탭(마크다운)만 다시 건다. 비마크다운(이미지/PDF/오피스/미디어)은 애초에 워처가
            // 없으므로(loadAndActivateDocument), 여기서 새로 만들면 외부 도구가 그 파일을
            // 쓸 때 바이너리를 UTF-8로 읽다 스퓨리어스 "Failed to reload file" 에러가 난다.
            let hadWatcher = fileWatchers[tab.id] != nil
            stopWatchingFile(for: tab.id)
            if hadWatcher, !isDirectoryPath(target) {
                startWatchingFile(at: target, for: tab.id)
            }
        }
    }

    /// url(폴더면 하위 포함)을 보는 열린 탭들을 닫는다.
    func closeTabs(under url: URL, isDirectory: Bool) {
        let basePath = url.standardizedFileURL.path
        let affected = tabs.filter { tab in
            guard let tabURL = tab.fileURL else { return false }
            let tabPath = tabURL.standardizedFileURL.path
            return tabPath == basePath || (isDirectory && tabPath.hasPrefix(basePath + "/"))
        }
        affected.forEach { closeTab($0) }
    }

    /// url 하위(또는 자신)에 더티 탭이 있는가 — 휴지통 확인 문구용.
    func hasDirtyTab(under url: URL, isDirectory: Bool) -> Bool {
        let basePath = url.standardizedFileURL.path
        return tabs.contains { tab in
            guard let tabURL = tab.fileURL else { return false }
            let tabPath = tabURL.standardizedFileURL.path
            let affected = tabPath == basePath || (isDirectory && tabPath.hasPrefix(basePath + "/"))
            return affected && isTabDirty(tab)
        }
    }

    /// 경로가 디렉터리인가(워처 재장전 가드용 — 탭은 파일만 보지만 방어적으로).
    func isDirectoryPath(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 특정 탭의 문서를 디스크에 저장한다(파일 URL 있는 문서만 — 없으면 false).
    /// 성공 시 그 탭의 더티 기준선(originalContents)을 "디스크에 쓴 내용"으로 갱신한다.
    /// 스냅샷을 documents에 통째로 되돌려쓰지 않는다 — 비동기 쓰기 중 입력된
    /// 키스트로크를 덮어쓰는 레이스 방지(saveCurrentDocument와 동일 규칙).
    @MainActor
    func saveDocument(forTabId tabId: UUID) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let document = documents[tab.documentId],
              let url = document.fileURL else { return false }
        do {
            try await fileService.saveDocument(document, to: url)
            originalContents[tab.documentId] = document.fullText
            if var live = documents[tab.documentId] {
                live.modifiedAt = Date()
                documents[tab.documentId] = live
            }
            return true
        } catch {
            return false
        }
    }

    func toggleTabPin(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].isPinned.toggle()

        if tabs[index].isPinned {
            let pinnedCount = tabs.prefix(index).filter { $0.isPinned }.count
            let movedTab = tabs.remove(at: index)
            tabs.insert(movedTab, at: pinnedCount)
        }
    }

    func moveTab(id: UUID, before targetId: UUID) {
        guard id != targetId,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        let insertIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(tab, at: insertIndex)
    }

    func selectNextTab() {
        guard !tabs.isEmpty, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        activeTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        activeTabId = tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        activeTabId = tabs[index].id
    }
}
