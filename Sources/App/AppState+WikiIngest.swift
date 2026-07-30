import Foundation

extension AppState {

    // MARK: - 위키 인제스트 흐름 (제안→확인→실행, 스펙 §2.5)

    /// 대상 페이지가 열린 탭에서 저장 안 된 편집 상태면 true — 인제스트/복원이 디스크를
    /// 덮으면 이후 사용자의 ⌘S가 병합 결과를 조용히 되덮는다(F1a rename flush와 동류).
    func wikiTargetHasDirtyTab(_ url: URL) -> Bool {
        guard let tab = tabs.first(where: { $0.fileURL == url }) else { return false }
        return isTabDirty(tab)
    }

    /// 병합 생성을 취소 가능한 태스크로 시작한다(시트 진입점). 완주·취소 모두 핸들을 비운다.
    @MainActor
    func startWikiMerge(source: URL, target: WikiIngestTarget) {
        wikiMergeTask?.cancel()
        wikiMergeTask = Task { @MainActor [weak self] in
            await self?.generateWikiMerge(source: source, target: target)
            self?.wikiMergeTask = nil
        }
    }

    /// 진행 중인 병합 생성 중단 — ClaudeService 폴링 루프가 취소를 보고 프로세스를 종료한다.
    /// 유휴 상태면 무동작(시트 닫기에서 무조건 불러도 안전).
    @MainActor
    func cancelWikiMerge() {
        wikiMergeTask?.cancel()
        wikiMergeTask = nil
    }

    /// 인제스트 시트 열기 — 이전 제안·에러를 비우고 소스를 지정한다.
    func requestWikiIngest(source: URL) {
        guard !wikiIngestBusy else {
            wikiIngestError = nil
            wikiIngestRequest = WikiIngestRequest(url: source)
            return
        }
        wikiMergeProposal = nil
        wikiIngestError = nil
        wikiIngestRequest = WikiIngestRequest(url: source)
    }

    /// 일괄 인제스트 시트 열기(다중 선택 진입점) — 파일만 남긴다(폴더 제외, 문서 단위 기능).
    /// 남는 파일이 없으면 토스트 안내 후 무동작.
    func requestWikiBatchIngest(sources: [URL]) {
        let files = sources.filter { !isDirectoryPath($0) }
        guard !files.isEmpty else {
            if !sources.isEmpty { showToast("인제스트할 파일이 없습니다(폴더 제외)") }
            return
        }
        if !wikiIngestBusy { wikiMergeProposal = nil }
        wikiIngestError = nil
        wikiBatchRequest = WikiBatchIngestRequest(files: files)
    }

    /// 병합 제안 생성 — busy 가드, 에러는 한국어 메시지로 시트에 표시.
    @MainActor
    func generateWikiMerge(source: URL, target: WikiIngestTarget) async {
        guard !wikiIngestBusy else { return }
        guard let folderPath = settings.wikiFolder else {
            wikiIngestError = "위키 폴더가 설정되지 않았습니다."
            return
        }
        if case .existing(let url) = target {
            // 자기 자신 인제스트 거부 — 소스=대상이면 병합이 무의미하고 자료 유실 위험만 있다
            // (kordoc fill isSameFile 전례). 심링크·경로 표기 차이는 실경로로 정규화해 비교.
            if url.resolvingSymlinksInPath().standardizedFileURL.path
                == source.resolvingSymlinksInPath().standardizedFileURL.path {
                wikiIngestError = "소스와 대상이 같은 페이지입니다 — 다른 대상을 선택하세요."
                return
            }
            if wikiTargetHasDirtyTab(url) {
                wikiIngestError = "이 페이지가 탭에서 저장 안 된 편집 상태입니다 — 저장 후 다시 시도하세요."
                return
            }
        }
        let trimmedRules = settings.wikiRulesSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if case .auto = target, trimmedRules?.isEmpty != false {
            // 자동 배치는 규칙 요약이 전제 — 시트가 열린 채 다른 창에서 요약을 비운
            // 스테일 .auto 선택도 여기서 걸린다(뷰의 선택 리셋과 이중 방어).
            wikiIngestError = "규칙 요약이 없습니다 — 설정 Wiki 탭에서 먼저 위키 규칙을 파악하세요."
            return
        }
        wikiIngestBusy = true
        wikiIngestError = nil
        wikiMergeProposal = nil
        defer { wikiIngestBusy = false }
        do {
            let today = Self.wikiTodayFormatter.string(from: Date())
            let proposal = try await wikiIngestService.propose(
                source: source, target: target,
                wikiFolder: URL(fileURLWithPath: folderPath),
                rulesSummary: (trimmedRules?.isEmpty == false) ? trimmedRules : nil,
                today: today)
            // propose가 프로세스 정상 종료 직후 취소 검사를 통과해 제안을 만든 경우에도(수 ms
            // 레이스), 대입 직전 한 번 더 취소를 본다 — "중단"이 stale 제안을 실제로 억제하도록.
            try Task.checkCancellation()
            wikiMergeProposal = proposal
        } catch let e as WikiIngestError {
            wikiIngestError = Self.wikiErrorMessage(e)
        } catch is CancellationError {
            // 사용자 중단(시트 "중단"·닫기) — 에러가 아니므로 조용히 끝낸다(무쓰기).
        } catch {
            wikiIngestError = Self.aiErrorMessage(error, provider: settings.aiProvider)
        }
    }

    /// 적용 — 백업 기록 후 페이지 덮어쓰기(새 페이지면 생성). 성공 시 실제 쓴 URL 반환.
    /// 제안 생성과 적용 사이의 변화(TOCTOU)에 방어한다: 새 페이지는 적용 시점에 재uniquify
    /// (그 사이 같은 이름 파일이 생겼으면 덮어쓰지 않고 비켜 감), 백업은 proposal의
    /// oldBody가 아니라 "적용 시점 디스크 본"을 저장한다(그 사이 편집분도 백업에 남게).
    @MainActor
    func applyWikiMerge(_ proposal: WikiMergeProposal) async -> URL? {
        do {
            let dest = proposal.isNewPage ? proposal.pageURL.uniquified() : proposal.pageURL
            if wikiTargetHasDirtyTab(dest) {
                wikiIngestError = "이 페이지가 탭에서 저장 안 된 편집 상태입니다 — 저장 후 다시 시도하세요."
                return nil
            }
            let currentBody = try? String(contentsOf: dest, encoding: .utf8)
            if !proposal.isNewPage && currentBody == nil {
                wikiIngestError = "대상 페이지를 다시 읽지 못했습니다 — 파일이 이동/삭제됐을 수 있습니다."
                return nil
            }
            _ = try await wikiBackupStore.recordApply(
                pageURL: dest,
                oldBody: proposal.isNewPage ? nil : currentBody,
                sourceName: proposal.sourceURL.lastPathComponent)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try proposal.newBody.write(to: dest, atomically: true, encoding: .utf8)
            if dest.standardizedFileURL.path != proposal.pageURL.standardizedFileURL.path {
                // 재uniquify로 비켜 갔으면 diff 승인 화면의 경로와 다르다 — 실제 파일명 안내.
                showToast("위키 페이지에 병합했습니다 — \(dest.lastPathComponent)(이름이 바뀌었습니다)")
            } else {
                showToast("위키 페이지에 병합했습니다")
            }
            completeFileOperation()   // 새 페이지·중간 폴더가 트리/라이브러리에 반영되도록.
            return dest
        } catch {
            wikiIngestError = "적용에 실패했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    /// 기록에서 되돌리기. 성공 여부 반환.
    @MainActor
    func restoreWikiIngest(_ entry: WikiIngestLogEntry) async -> Bool {
        if wikiTargetHasDirtyTab(entry.pageURL) {
            wikiIngestError = "이 페이지가 탭에서 저장 안 된 편집 상태입니다 — 저장 후 다시 시도하세요."
            return false
        }
        do {
            try await wikiBackupStore.restore(entry)
            showToast("되돌렸습니다")
            completeFileOperation()   // 복원(새 페이지 복원=휴지통 이동 포함)도 갱신 트리거.
            return true
        } catch {
            wikiIngestError = "되돌리기에 실패했습니다: \(error.localizedDescription)"
            return false
        }
    }

    static func wikiErrorMessage(_ e: WikiIngestError) -> String {
        switch e {
        case .sourceUnreadable: return "소스 문서의 본문을 읽지 못했습니다(미지원 형식이거나 변환 실패)."
        case .pageUnreadable: return "대상 페이지를 읽지 못했습니다."
        case .pageTooLarge: return "페이지가 너무 큽니다(24,000자 초과) — 분할 후 다시 시도하세요."
        case .invalidNewPageName: return "새 페이지 이름이 비어 있거나 쓸 수 없습니다."
        case .badResponse: return "Claude 응답이 페이지 전문 형식이 아닙니다 — 다시 시도하세요."
        case .autoPathInvalid: return "Claude가 배치 위치를 제안하지 못했습니다 — 다시 시도하거나 폴더를 직접 선택하세요."
        case .autoPathOccupied(let path): return "제안된 경로에 이미 페이지가 있습니다: \(path)"
        }
    }
}
