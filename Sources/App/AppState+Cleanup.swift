import Foundation

extension AppState {

    // MARK: - Toast

    // MARK: - 폴더 정리 (Phase 8)

    // busy(배정 등 진행) 중엔 아래 진입점들이 상태를 초기화하지 않는다 — 진행 중 세션
    // 위로 리셋하면 완료 시점 plan 대입이 새 세션을 덮어쓰고, plan.scheme이 시작 시점
    // 스냅샷이라 옛 폴더의 파일이 실제로 이동 가능해진다(적대적 리뷰 확증, 2026-07-05).
    // 시트가 닫혀 있어도 배정 태스크는 계속 돌므로(비구조적 Task) 시트만 다시 보여준다.

    /// subfolder 모드 진입: 시트를 열고 이전 상태를 초기화한다. busy 중엔 시트만 표시.
    func startCleanup(folder: URL) {
        guard !cleanupBusy else { showFolderCleanup = true; return }
        cleanupMode = .subfolder(root: folder)
        cleanupScheme = []
        cleanupPlan = nil
        cleanupError = nil
        showFolderCleanup = true
    }

    /// PARA 모드 진입: 설정된 PARA 폴더를 스킴으로 쓴다. busy 중엔 시트만 표시.
    func startCleanupToPara(vault: Vault) {
        guard !cleanupBusy else { showFolderCleanup = true; return }
        cleanupMode = .para(vault: vault)
        cleanupScheme = settings.paraFolders.map { CleanupBucket.from(para: $0) }
        cleanupPlan = nil
        cleanupError = nil
        showFolderCleanup = true
    }

    /// 정리 UI 상태를 완전히 초기화한다(커맨드팔레트 재진입 시 사용). busy 중엔 무시.
    func resetCleanup() {
        guard !cleanupBusy else { return }
        cleanupMode = nil
        cleanupScheme = []
        cleanupPlan = nil
        cleanupError = nil
    }

    /// 1단계: 폴더 스캔 후 스킴을 제안한다(배정은 하지 않음). subfolder 모드만 Claude 호출.
    @MainActor
    func proposeCleanupScheme() async {
        guard let mode = cleanupMode else { return }
        cleanupBusy = true
        cleanupError = nil
        defer { cleanupBusy = false }
        let metas = FileScanner.scan(mode.root)
        guard !metas.isEmpty else { showToast("정리할 파일이 없습니다"); return }
        do {
            if cleanupScheme.isEmpty {
                if case .subfolder = mode {
                    let proposed = try await cleanupService.proposeScheme(metas: metas)
                    // 방어선: 배정과 동일 — 세션이 그대로일 때만 반영(스테일 완료 폐기).
                    guard cleanupMode == mode else { return }
                    cleanupScheme = proposed
                } else {
                    showToast("PARA 폴더가 설정돼 있지 않습니다"); return
                }
            }
            // 스킴만 제시하고 사용자 편집을 기다린다. plan은 아직 만들지 않는다.
            cleanupPlan = nil
        } catch let error as ClaudeError {
            cleanupError = Self.aiErrorMessage(error, provider: settings.aiProvider)
        } catch {
            showToast("AI 응답을 해석하지 못했습니다")
        }
    }

    /// 2단계: 확정된(편집된) 스킴으로 배정해 미리보기 plan을 만든다.
    @MainActor
    func assignCleanupPlan() async {
        guard let mode = cleanupMode, !cleanupScheme.isEmpty else { return }
        cleanupBusy = true
        cleanupError = nil
        defer { cleanupBusy = false; cleanupProgress = nil }
        // 배정 시작 시점 스킴 스냅샷 — 배정(대형 폴더는 수십 분) 도중 스킴이 편집돼도
        // 배정 결과와 plan이 같은 스킴을 본다. 완료 시점에 live cleanupScheme을 다시 읽으면
        // 도중 삭제된 버킷의 move가 적용 시 MoveExecutor 가드에서 조용히 실패로 떨어진다.
        let scheme = cleanupScheme
        let metas = FileScanner.scan(mode.root)
        guard !metas.isEmpty else { showToast("정리할 파일이 없습니다"); return }
        do {
            let assignments = try await cleanupService.assign(scheme: scheme, metas: metas) { [weak self] done, total in
                guard total > 1 else { return }  // 단일 청크면 기본 문구 유지
                Task { @MainActor in self?.cleanupProgress = "배정 중… (\(done)/\(total))" }
            }
            // 방어선: 진입점 busy 가드로 도중 리셋은 차단되지만, 세션(cleanupMode)이
            // 그대로일 때만 결과를 반영한다 — 스테일 완료가 새 세션을 덮어쓰는 것 방지.
            guard cleanupMode == mode else { return }
            cleanupPlan = CleanupPlan(mode: mode, scheme: scheme,
                                      moves: CleanupPlanner.buildMoves(from: assignments))
        } catch let error as ClaudeError {
            cleanupError = Self.aiErrorMessage(error, provider: settings.aiProvider)
        } catch {
            showToast("AI 응답을 해석하지 못했습니다")
        }
    }

    /// 승인된 move만 실행하고 로그를 갱신한다.
    @MainActor
    func applyCleanup() async {
        guard let plan = cleanupPlan else { return }
        cleanupBusy = true
        defer { cleanupBusy = false }
        let outcome = await moveExecutor.apply(plan: plan, mode: plan.mode)
        await loadCleanupBatches()
        cleanupPlan = nil
        let failedNote = outcome.failed.isEmpty ? "" : ", 실패 \(outcome.failed.count)"
        showToast("정리 완료: \(outcome.moved)개 이동\(failedNote)")
    }

    /// 정리 배치를 되돌린다.
    @MainActor
    func undoCleanupBatch(_ batch: MoveBatch) async {
        let result = await moveExecutor.undo(batch)
        await loadCleanupBatches()
        showToast("되돌리기: \(result.restored)개 복귀")
    }

    /// 영속 로그에서 배치 목록을 불러온다(최신 순).
    @MainActor
    func loadCleanupBatches() async {
        cleanupBatches = await moveLogStore.load().reversed()
    }

    /// 위키 폴더 지정/변경 — 심링크는 실경로로 정규화(진입점 공통), 폴더가 바뀌면
    /// 이전 위키의 규칙 요약·일시를 비운다(옛 규칙이 새 위키 인제스트를 조종하는 스테일 방지).
    @MainActor
    func setWikiFolder(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath().path
        guard settings.wikiFolder != resolved else { return }
        settings.wikiFolder = resolved
        settings.wikiRulesSummary = nil
        settings.wikiRulesCapturedAt = nil
        wikiRulesMessage = "위키 폴더가 바뀌었습니다 — 규칙을 다시 파악하세요."
        saveUserData()
    }

    /// 위키 규칙 파악(스펙 §2.1) — 성공 시 요약·일시를 설정에 저장. 성공 여부 반환.
    @MainActor
    func captureWikiRules() async -> Bool {
        guard !wikiRulesBusy else { return false }
        guard let folderPath = settings.wikiFolder else {
            wikiRulesMessage = "위키 폴더가 설정되지 않았습니다."
            return false
        }
        wikiRulesBusy = true
        wikiRulesMessage = nil
        defer { wikiRulesBusy = false }
        do {
            let summary = try await wikiRulesService.captureRules(
                wikiFolder: URL(fileURLWithPath: folderPath))
            settings.wikiRulesSummary = summary
            settings.wikiRulesCapturedAt = Date()
            saveUserData()
            wikiRulesMessage = "규칙을 파악했습니다."
            return true
        } catch WikiRulesError.noRuleSources {
            wikiRulesMessage = "규칙 파일(CLAUDE.md·templates)이 없습니다 — 내장 기본 스키마로 동작합니다."
            return false
        } catch {
            wikiRulesMessage = "규칙 파악에 실패했습니다: \(error.localizedDescription)"
            return false
        }
    }
}
