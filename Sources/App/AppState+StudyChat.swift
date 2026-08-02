import Foundation

/// 학습도우미 대화(S3) — `StudyChatView` 배선. 실제 로직은 `StudyChatService`(actor,
/// 스트림·취소·접기 정책)·`ChatContextAssembler`(순수, 예산·트리밍)·`StudyNoteWriter`(저장)에
/// 있고, 이 파일은 화면 상태·시작·전송·중단·저장만 잇는다(설계 §4.1~4.4).
extension AppState {

    /// 이 개수를 넘는 오래된 턴은 보내기 전에 미리 접는다(§4.2.2 "턴 유지 개수"). 아직 설정
    /// 화면에 노출된 값이 아니라 잠정 기본값 — 실사용 뒤 설정 키 승격 여부 재검토
    /// (`docs/todolist.md` 참고, S1의 `studyChunkBudget`과 같은 결정).
    static let studyChatKeepRecentTurns = 12

    // MARK: - 시작(학습도우미 S1 화면에서 고른 범위를 그대로 재사용)

    /// 학습도우미에서 고른 파일·범위로 새 대화를 시작한다. 핀 발췌는 그 범위의 세그먼트를
    /// 위치 태그와 함께 이어붙인 것(`StudySourceLoader`+`StudyChunker.taggedText` — 카드·문제
    /// 생성과 같은 경로 재사용). 진행 중이던 대화가 있으면 스트림을 끊고 새로 시작한다.
    @MainActor
    func startStudyChat() {
        guard let scope = currentStudyScope() else {
            studyChatError = "먼저 학습할 파일을 선택하세요."
            return
        }
        if let priorId = studyChatSession?.id {
            Task { await studyChatService.cancel(sessionId: priorId) }
        }
        studyChatSession = nil
        studyChatText = ""
        studyChatError = nil
        studyChatNotice = nil
        studyChatSavedNoteURL = nil
        studyChatBusy = true
        // 학습도우미는 이제 메인 화면 모드라 따로 닫지 않는다 — 대화 시트가 그 위에 뜬다.
        showStudyChat = true

        Task { @MainActor in
            defer { studyChatBusy = false }
            let segments = await studySourceLoader.segments(for: scope)
            guard !segments.isEmpty else {
                studyChatError = "선택한 범위에서 읽을 수 있는 글자를 찾지 못했습니다."
                return
            }
            studyChatSession = StudyChatSession(
                sourceURL: scope.fileURL,
                pinnedExcerpt: StudyChunker.taggedText(from: segments))
        }
    }

    // MARK: - 전송

    /// 입력창의 질문을 보낸다. 사용자 턴은 즉시 화면에 반영하고, 도우미 턴은 스트리밍으로
    /// 실시간 채운다. `.noSend`/실패 시엔 아무것도 보내지 않은 것처럼 되돌린다(부분 전송 없음).
    @MainActor
    func sendStudyChatMessage() async {
        let question = studyChatText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let session = studyChatSession, !studyChatBusy else { return }
        studyChatText = ""
        studyChatBusy = true
        studyChatError = nil
        studyChatNotice = nil

        let sessionId = session.id
        var displayTurns = session.turns
        displayTurns.append(StudyChatTurn(role: .user, text: question))
        let assistantIndex = displayTurns.count
        displayTurns.append(StudyChatTurn(role: .assistant, text: ""))
        studyChatSession?.turns = displayTurns

        let (outcome, folded, keptTurns) = await studyChatService.sendTurn(
            sessionId: sessionId,
            cap: settings.chatContextCap,
            keepRecentTurns: Self.studyChatKeepRecentTurns,
            pinnedExcerpt: session.pinnedExcerpt,
            foldedPrefix: session.foldedPrefix,
            recentTurns: session.turns,
            question: question,
            aiSummaryEnabled: settings.studyChatAISummary
        ) { [weak self] delta in
            guard let self, self.studyChatSession?.id == sessionId,
                  var turns = self.studyChatSession?.turns, assistantIndex < turns.count else { return }
            turns[assistantIndex].text += delta
            self.studyChatSession?.turns = turns
        }

        // 진행 중 세션이 닫혔거나(사용자가 화면을 닫음) 다른 세션으로 바뀌었으면 반영하지 않는다.
        guard studyChatSession?.id == sessionId else {
            studyChatBusy = false
            return
        }

        switch outcome {
        case .assembled(let reply, let questionTruncated, let trimmed):
            var turns = keptTurns
            turns.append(StudyChatTurn(role: .user, text: question, truncated: questionTruncated))
            turns.append(StudyChatTurn(role: .assistant, text: reply))
            studyChatSession?.foldedPrefix = folded
            studyChatSession?.turns = turns
            if trimmed {
                studyChatNotice = "이전 대화 일부를 줄여서 보냈어요."
            }
        case .cancelled(let partial):
            var turns = keptTurns
            turns.append(StudyChatTurn(role: .user, text: question))
            turns.append(StudyChatTurn(role: .assistant, text: partial.isEmpty ? "(중단됨)" : partial + "\n(중단됨)"))
            studyChatSession?.foldedPrefix = folded
            studyChatSession?.turns = turns
        case .noSend(let reason):
            studyChatSession?.turns = session.turns
            studyChatText = question
            studyChatError = Self.studyChatNoSendMessage(reason)
        case .failed(let error):
            studyChatSession?.turns = session.turns
            studyChatText = question
            studyChatError = Self.aiErrorMessage(error, provider: settings.aiProvider)
        }
        studyChatBusy = false
    }

    private static func studyChatNoSendMessage(_ reason: ChatContextAssembler.NoSendReason) -> String {
        switch reason {
        case .capTooSmall:
            return "보낼 수 있는 자리가 없습니다. 설정에서 한 번에 보낼 글자 수를 늘려 주세요."
        case .cannotFitAfterTrim:
            return "대화가 길어져 줄여도 보낼 자리가 없습니다. 설정에서 한 번에 보낼 글자 수를 늘리거나 새 대화를 시작해 주세요."
        }
    }

    // MARK: - 중단(AC #19)

    /// 진행 중인 스트림을 끊는다 — busy 해제·부분 텍스트 보존은 `sendStudyChatMessage()`가
    /// `.cancelled` 결과를 받아 처리한다(여기서는 취소 신호만 보낸다).
    @MainActor
    func stopStudyChat() {
        guard let id = studyChatSession?.id else { return }
        Task { await studyChatService.cancel(sessionId: id) }
    }

    // MARK: - 닫기(정상 종료 경로 — AC #20, 크래시 대비 초안은 이번 슬라이스 범위 밖)

    @MainActor
    func closeStudyChat() {
        if let id = studyChatSession?.id {
            Task { await studyChatService.cancel(sessionId: id) }
        }
        showStudyChat = false
        studyChatSession = nil
        studyChatText = ""
        studyChatError = nil
        studyChatNotice = nil
        studyChatBusy = false
        studyChatSavedNoteURL = nil
    }

    // MARK: - 저장(제안 → 확인 → 실행, AC #21 "화면의 원본 턴 전문을 저장한다")

    @MainActor
    func saveStudyChatAsNote() async {
        guard let session = studyChatSession, !session.turns.isEmpty else {
            studyChatError = "저장할 대화가 없습니다."
            return
        }
        guard let vault = defaultVault else {
            studyChatError = "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요."
            return
        }
        let targetDir = vault.rootPath.appendingPathComponent(effectiveSendFolder(for: vault))
        let sourceName = session.sourceURL?.deletingPathExtension().lastPathComponent ?? "대화"
        let sourceKind = (session.sourceURL == studyScopeFileURL) ? studyScopeKind : nil
        do {
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            let title = "\(sourceName) 대화"
            let result = StudyNoteWriter.buildChatNote(
                session: session, sourceKind: sourceKind, noteFolder: targetDir, title: title)
            let filename = Self.sanitizedFilename(title) + ".md"
            let targetURL = targetDir.appendingPathComponent(filename).uniquified()
            try result.body.write(to: targetURL, atomically: true, encoding: .utf8)
            studyChatSavedNoteURL = targetURL
            loadFileTree()
        } catch {
            studyChatError = "노트 저장 실패: \(error.localizedDescription)"
        }
    }

    /// 저장 직후 "노트 열기" — 사용자가 눌러야만 연다(자동 열기 없음, `openSavedStudyNote()` 전례).
    @MainActor
    func openSavedStudyChatNote() {
        guard let url = studyChatSavedNoteURL else { return }
        openDocument(at: url, inNewTab: true)
        closeStudyChat()
    }
}
