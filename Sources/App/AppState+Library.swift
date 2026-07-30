import Foundation
import AppKit

extension AppState {

    // MARK: - Recents & Favorites

    func addToRecentFiles(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 {
            recentFiles = Array(recentFiles.prefix(20))
        }
        saveUserData()
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        saveUserData()
    }

    func addToFavorites(_ url: URL) {
        guard !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(FavoriteItem(url: url))
        saveUserData()
        showToast("Added to favorites")
    }

    func removeFromFavorites(_ favorite: FavoriteItem) {
        favorites.removeAll { $0.id == favorite.id }
        saveUserData()
    }

    // MARK: - Quick Move

    func addToQuickMoveFolders(_ url: URL) {
        guard !quickMoveFolders.contains(where: { $0.url == url }) else { return }
        quickMoveFolders.append(QuickMoveFolder(url: url))
        saveUserData()
        showToast("빠른 이동 목록에 추가했습니다")
    }

    func removeFromQuickMoveFolders(_ folder: QuickMoveFolder) {
        quickMoveFolders.removeAll { $0.id == folder.id }
        saveUserData()
    }

    func isQuickMoveFolder(_ url: URL) -> Bool {
        quickMoveFolders.contains(where: { $0.url == url })
    }

    /// "빠른 이동…" — 선택 파일을 등록된 목적지 목록에서 고르게 한다. urls nil이면 현재 선택.
    func promptQuickMove(urls: [URL]? = nil) {
        let targets = urls ?? Array(fileSelection)
        guard !targets.isEmpty else { return }
        quickMoveTargets = targets
        showQuickMove = true
    }

    // MARK: - Vaults

    func addVault(_ vault: Vault) {
        vaults.append(vault)
        saveUserData()
        rebuildNoteIndex()
        Task { @MainActor in self.registerIndexFolder(vault.rootPath) }   // 연결하면 자동으로 내용까지 훑는다.
    }

    func removeVault(_ vault: Vault) {
        vaults.removeAll { $0.id == vault.id }
        routingRules.removeAll { $0.targetVaultId == vault.id }
        saveUserData()
        rebuildNoteIndex()
    }

    // MARK: - Send to Vault

    func sendToVault(options: SendOptions) async throws {
        guard let document = currentDocument else {
            throw SendError.noDocumentOrVault
        }
        try await sendToVault(document: document, options: options)
    }

    /// Sends an explicit document. Used directly by menu-bar Quick Capture, which
    /// has no active tab and therefore can't rely on `currentDocument`.
    func sendToVault(document: MarkdownDocument, options: SendOptions, quiet: Bool = false) async throws {
        guard let vault = options.targetVault else {
            throw SendError.noDocumentOrVault
        }

        let targetDir = vault.rootPath.appendingPathComponent(options.targetFolder)
        if !FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let template: VaultTemplate? = options.applyTemplate
            ? templates.first(where: { $0.id == options.templateId })
            : nil

        let baseName = template?.generateFilename(title: document.displayTitle) ?? document.displayTitle
        let filename = Self.sanitizedFilename(baseName) + ".md"
        let candidateURL = targetDir.appendingPathComponent(filename)

        guard let targetURL = resolveConflict(for: candidateURL, resolution: options.conflictResolution) else {
            // .skip on an existing file must leave both target and source intact.
            if !quiet { showToast("Skipped: \(filename) already exists") }
            return
        }

        let body = template?.renderContent(for: document) ?? document.content

        let contentToWrite: String
        if options.injectFrontmatter {
            // Preserve the document's REAL frontmatter (tags, dates, custom keys)
            // instead of synthesizing a minimal one that discards user metadata.
            var frontmatter = document.frontmatter ?? Frontmatter(title: document.displayTitle, date: Date())
            if frontmatter.title == nil { frontmatter.title = document.displayTitle }
            if options.addSourceLink, let source = document.fileURL {
                frontmatter.custom["source"] = .string(source.path)
            }
            contentToWrite = frontmatter.toYAML() + "\n\n" + body
        } else if template != nil {
            contentToWrite = body
        } else {
            // No injection and no template: ship the file exactly as it is on
            // disk. Writing `content` alone silently stripped existing
            // frontmatter from the copy.
            contentToWrite = document.fullText
        }

        try contentToWrite.write(to: targetURL, atomically: true, encoding: .utf8)

        if options.action == .move, let sourceURL = document.fileURL {
            try FileManager.default.removeItem(at: sourceURL)
            // Detach the in-app tab from the now-deleted source file.
            if document.id == currentDocument?.id, var current = currentDocument {
                current.fileURL = nil
                currentDocument = current
                if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[index].fileURL = nil
                    stopWatchingFile(for: tabId)
                }
            }
        }

        if !quiet { showToast("Sent to \(vault.displayName)") }

        if options.openAfterSend, let obsidianURL = vault.obsidianURL(forFile: targetURL) {
            NSWorkspace.shared.open(obsidianURL)
        }
    }

    /// Sends a batch of files with the same options. Returns counts for the
    /// summary toast. Used by "Send Folder to Vault…".
    @MainActor
    @discardableResult
    func sendFiles(_ urls: [URL], options: SendOptions) async -> (sent: Int, failed: Int) {
        var sent = 0, failed = 0
        for url in urls {
            do {
                let document = try await fileService.loadDocument(from: url)
                try await sendToVault(document: document, options: options, quiet: true)
                sent += 1
            } catch {
                failed += 1
            }
        }
        showToast("Sent \(sent) of \(urls.count) files" + (failed > 0 ? " (\(failed) failed)" : ""))
        return (sent, failed)
    }

    // MARK: - Routing Rules

    /// Highest-priority enabled rule whose conditions all match (a rule with no
    /// conditions acts as a catch-all) and whose target vault still exists.
    func matchingRoutingRule(for document: MarkdownDocument) -> RoutingRule? {
        routingRules
            .filter { $0.isEnabled }
            .sorted { $0.priority > $1.priority }
            .first { rule in
                vaults.contains(where: { $0.id == rule.targetVaultId }) &&
                rule.conditions.allSatisfy { $0.matches(document: document) }
            }
    }

    /// One-keystroke routed send: evaluates routing rules against the current
    /// document and sends without showing a dialog. Falls back to the Send
    /// sheet when no rule matches.
    func autoRouteCurrentDocument() {
        guard let document = currentDocument else { return }
        guard let rule = matchingRoutingRule(for: document),
              let vault = vaults.first(where: { $0.id == rule.targetVaultId }) else {
            if settings.claudeRoutingEnabled && isParaRoutingConfigured() {
                autoTriggerClaudeRoute = true   // 시트가 onAppear에서 소비해 자동 제안
            } else {
                showToast("No routing rule matches — opening Send dialog")
            }
            showSendToVault = true
            return
        }

        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = rule.targetFolder
        options.action = rule.action
        options.conflictResolution = settings.conflictResolution
        options.injectFrontmatter = rule.injectFrontmatter

        Task { @MainActor in
            do {
                try await sendToVault(document: document, options: options, quiet: true)
                showToast("Routed to \(vault.displayName)/\(rule.targetFolder) (\(rule.name))")
            } catch {
                errorMessage = "Auto-route failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Conflict Resolution

    /// Returns the URL to write to, or `nil` when the write should be skipped
    /// (the file exists and resolution is `.skip`). Distinguishing skip from
    /// overwrite is what stops "Skip" from silently clobbering the existing note.
    func resolveConflict(for url: URL, resolution: FileConflictResolution) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        switch resolution {
        case .overwrite:
            return url
        case .skip:
            return nil
        case .rename:
            return url.uniquified()
        case .timestamp:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let parent = url.deletingLastPathComponent()
            return parent.appendingPathComponent("\(baseName)_\(timestamp).\(ext)").uniquified()
        }
    }

    static func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
