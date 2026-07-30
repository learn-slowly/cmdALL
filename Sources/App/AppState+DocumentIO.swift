import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {

    // MARK: - Saving

    @MainActor
    func saveCurrentDocument() async {
        guard let document = currentDocument else { return }

        if let url = document.fileURL {
            do {
                try await fileService.saveDocument(document, to: url)
                // Update the dirty baseline to exactly what we wrote. We do NOT
                // reassign the whole captured snapshot back into currentDocument:
                // doing so would clobber any keystrokes the user made while the
                // async write was in flight. We only stamp modifiedAt on the
                // live document.
                originalContent = document.fullText
                if var current = currentDocument {
                    current.modifiedAt = Date()
                    currentDocument = current
                }
                showToast("Saved")
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        } else {
            await saveDocumentAs()
        }
    }

    @MainActor
    func saveDocumentAs() async {
        guard let document = currentDocument else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.nameFieldStringValue = document.displayTitle + ".md"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                var doc = document
                doc.fileURL = url
                doc.modifiedAt = Date()
                let wasDraft = doc.isDraft
                doc.isDraft = false
                try await fileService.saveDocument(doc, to: url)
                currentDocument = doc
                originalContent = doc.fullText
                // Persist the new URL on the tab too, otherwise dedup/watching/
                // breadcrumb logic that keys off tab.fileURL stays out of sync.
                if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[index].fileURL = url
                    tabs[index].title = doc.displayTitle
                    startWatchingFile(at: url, for: tabId)
                }
                // A draft that became a real file graduates out of the drafts list.
                if wasDraft {
                    drafts.removeAll { $0.id == doc.id }
                    saveUserData()
                }
                addToRecentFiles(url)
                saveSession()
                showToast("Saved")
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }

    /// Saves every file-backed dirty tab. Used by the save-on-quit guard.
    /// Unsaved (no fileURL) tabs are skipped since they'd require a Save panel.
    @MainActor
    func saveAllDirtyTabs() async {
        for tab in tabs {
            guard let doc = documents[tab.documentId],
                  let url = doc.fileURL,
                  isTabDirty(tab) else { continue }
            do {
                try await fileService.saveDocument(doc, to: url)
                originalContents[tab.documentId] = doc.fullText
            } catch {
                errorMessage = "Failed to save \(tab.displayTitle): \(error.localizedDescription)"
            }
        }
    }

    func updateContent(_ newContent: String) {
        currentDocument?.content = newContent
        currentDocument?.modifiedAt = Date()
        if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[index].isDirty = isDirty
        }
        // Keep the backing draft in sync while a draft is being edited so its
        // content survives restarts even without an explicit save.
        if let doc = currentDocument, doc.isDraft,
           let draftIndex = drafts.firstIndex(where: { $0.id == doc.id }) {
            drafts[draftIndex].body = newContent
            drafts[draftIndex].updatedAt = Date()
            scheduleDraftPersist()
        }
        scheduleAutosaveIfNeeded()
    }

    func updateCursorPosition(line: Int, column: Int) {
        if cursorLine != line { cursorLine = line }
        if cursorColumn != column { cursorColumn = column }
    }

    /// Flips a `- [ ]`/`- [x]` marker on the given 1-based source line. Invoked
    /// by checkbox clicks in the preview. The line is re-validated against the
    /// task pattern before mutating so a stale line number can never corrupt
    /// unrelated text.
    func toggleTask(atLine line: Int, checked: Bool) {
        guard let doc = currentDocument else { return }
        var lines = doc.content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }

        let target = lines[line - 1]
        let ns = target as NSString
        guard let match = TaskLineQueue.taskLinePattern.firstMatch(
            in: target,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            showToast("Couldn't toggle that task")
            return
        }

        let markerRange = match.range(at: 2)
        lines[line - 1] = ns.replacingCharacters(in: markerRange, with: checked ? "x" : " ")
        updateContent(lines.joined(separator: "\n"))
    }

    /// Debounced autosave: each edit reschedules, so a save fires only after the
    /// user pauses for `autosaveInterval` seconds. Only saves file-backed
    /// documents so it never pops a Save panel unexpectedly.
    func scheduleAutosaveIfNeeded() {
        guard settings.autosaveEnabled, currentDocument?.fileURL != nil else { return }
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.settings.autosaveEnabled,
                      self.currentDocument?.fileURL != nil, self.isDirty else { return }
                await self.saveCurrentDocument()
            }
        }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, settings.autosaveInterval), execute: work)
    }

    func scheduleDraftPersist() {
        draftPersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistDrafts()
        }
        draftPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func createNewDraft() {
        let draft = Draft()
        drafts.insert(draft, at: 0)
        persistDrafts()
        openDraft(draft)
        viewMode = .source
    }

    func addDraft(_ draft: Draft) {
        drafts.insert(draft, at: 0)
        persistDrafts()
    }

    func deleteDraft(_ draft: Draft) {
        drafts.removeAll { $0.id == draft.id }
        // Close any tab editing this draft.
        if let tab = tabs.first(where: { $0.documentId == draft.id }) {
            closeTab(tab)
        }
        persistDrafts()
    }

    func openDraft(_ draft: Draft) {
        if let existingTab = tabs.first(where: { $0.documentId == draft.id }) {
            activeTabId = existingTab.id
            return
        }

        let document = draft.toDocument()
        let tab = EditorTab(
            documentId: document.id,
            title: draft.displayTitle
        )

        documents[document.id] = document
        originalContents[document.id] = document.fullText
        tabs.append(tab)
        activeTabId = tab.id
    }

    func createNewTab() {
        let document = MarkdownDocument()
        let tab = EditorTab(
            documentId: document.id,
            title: "Untitled"
        )

        documents[document.id] = document
        originalContents[document.id] = document.fullText
        tabs.append(tab)
        activeTabId = tab.id
        viewMode = .source
    }

    // MARK: - Tabs

    func closeTab(_ tab: EditorTab) {
        stopWatchingFile(for: tab.id)
        documents.removeValue(forKey: tab.documentId)
        originalContents.removeValue(forKey: tab.documentId)
        officeStates.removeValue(forKey: tab.id)
        officeOriginalRenderStates.removeValue(forKey: tab.id)
        pendingMediaScrollLines.removeValue(forKey: tab.id)
        mediaPlayers.removeValue(forKey: tab.id)?.pause()

        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)

        if activeTabId == tab.id {
            if tabs.isEmpty {
                activeTabId = nil
            } else if index < tabs.count {
                activeTabId = tabs[index].id
            } else {
                activeTabId = tabs.last?.id
            }
        }
        saveSession()
    }

    // MARK: - Export

    func exportAsHTML() {
        guard let document = currentDocument else { return }
        exportService.saveHTML(document: document, options: renderOptions())
    }

    func exportAsPDF() {
        guard let document = currentDocument else { return }
        exportService.savePDF(document: document, options: renderOptions())
    }

    func copyAsHTML() {
        guard let document = currentDocument else { return }
        exportService.copyAsHTML(document: document, options: renderOptions())
        showToast("Copied as HTML")
    }

    /// The render configuration shared by the live preview and all exporters.
    func renderOptions() -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            theme: PreviewTheme(rawValue: settings.previewTheme) ?? .github,
            preview: settings.previewSettings,
            enableWikiLinks: settings.enableWikiLinks,
            enableCallouts: settings.enableCallouts,
            enableMermaid: settings.enableMermaid,
            enableKaTeX: settings.enableKaTeX,
            enableCodeHighlight: settings.enablePreviewCodeHighlight
        )
    }
}
