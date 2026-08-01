import Foundation

/// 이번 턴에 Claude로 보낼 대화 컨텍스트를, 정해진 글자 수(`cap`) 안에 맞춰 조립한다
/// (순수 함수, 설계 §4.2). 예산 배분(§4.2.2)과 유한 트리밍(§4.2.3)을 그대로 따르며,
/// 부분 전송은 없다 — `.assembled`(전체가 cap 이하로 들어감) 아니면
/// `.noSend`(이유 포함)만 돌려준다.
///
/// AI를 부르지 않는 **순수 함수**다. `studyChatAISummary`(옵트인 AI 요약, §4.3)는 이 함수가
/// 아니라 `StudyChatService`(예정)가 턴을 접기 전에 미리 처리하는 정책이고, 여기서는 그
/// 결과로 넘어온 `foldedPrefix`를 그대로 다룰 뿐이다. 다만 여기서도 예산이 모자라 턴을 더
/// 밀어내야 할 때는(2단계) AI 없이 §4.3의 결정적 접기("역할: 앞 200자…")로 대체한다 —
/// 순수성을 지키면서도 밀려난 턴이 흔적 없이 사라지지 않게 하기 위함이다(AC18).
enum ChatContextAssembler {

    enum NoSendReason: Equatable {
        /// 프레이밍(고정 틀)만으로도 cap을 못 채우거나(P ≥ cap), 이번 질문에 배정할
        /// 자리가 0인 경우(§4.2.2 3·6단계).
        case capTooSmall
        /// 4단계 트리밍을 전부 거쳐도 cap을 못 맞춘 경우.
        case cannotFitAfterTrim
    }

    enum Result: Equatable {
        case assembled(String)
        case noSend(NoSendReason)
    }

    /// §4.2.2 배분 공식의 계산 결과. 테스트에서 직접 검산할 수 있도록 노출한다(AC31 e).
    struct BudgetSplit: Equatable {
        let reserve: Int
        let framingLength: Int
        let contentBudget: Int
        /// 잔여(0~3자, §4.2.2 5단계)가 이미 가산된 값.
        let pinBudget: Int
        let foldedBudget: Int
        let recentBudget: Int
        let questionBudget: Int
    }

    private static let foldMarker = "…(생략)"

    /// §4.2.2 배분 공식만 떼어낸 순수 계산. `framingLength`는 이번 호출의 실제 프레이밍
    /// 길이(§4.2.1 "P를 먼저 실측")를 호출부가 이미 잰 값이다.
    static func budgetSplit(cap: Int, framingLength: Int) -> BudgetSplit {
        let reserve = Int((Double(cap) * 0.08).rounded(.up))
        let contentBudget = max(0, cap - max(reserve, framingLength))
        let pin0 = Int(Double(contentBudget) * 0.60)
        let folded = Int(Double(contentBudget) * 0.10)
        let recent = Int(Double(contentBudget) * 0.25)
        let question = Int(Double(contentBudget) * 0.05)
        let remainder = contentBudget - (pin0 + folded + recent + question)
        return BudgetSplit(
            reserve: reserve,
            framingLength: framingLength,
            contentBudget: contentBudget,
            pinBudget: pin0 + remainder,
            foldedBudget: folded,
            recentBudget: recent,
            questionBudget: question
        )
    }

    /// §4.2.1 "P를 먼저 실측" — 이번 입력을 그대로 조립했을 때, 가변 내용(발췌·요약·턴
    /// 텍스트·질문)을 뺀 나머지(헤더·역할 라벨·구분선·개행)의 길이. 테스트에서 정확한
    /// 경계값(cap을 P 바로 위/아래로 맞추기)을 잡을 수 있도록 노출한다.
    static func framingLength(
        pinnedExcerpt: String, foldedPrefix: String?, recentTurns: [StudyChatTurn], question: String
    ) -> Int {
        let initial = render(pin: pinnedExcerpt, folded: foldedPrefix, turns: recentTurns, question: question)
        let contentLength = pinnedExcerpt.count
            + (foldedPrefix?.count ?? 0)
            + recentTurns.reduce(0) { $0 + $1.text.count }
            + question.count
        return initial.count - contentLength
    }

    /// - Parameters:
    ///   - cap: 전송 컨텍스트 전체 길이 상한(문자 수). 설정 `chatContextCap`, 양의 정수만 유효.
    ///   - pinnedExcerpt: 교재에서 골라 고정한 발췌(세션 내내 유지).
    ///   - foldedPrefix: 이미 접힌 이전 대화 요약(없으면 nil).
    ///   - recentTurns: 아직 접히지 않은 최근 턴들, 오래된 순서대로.
    ///   - question: 이번에 사용자가 막 입력한 질문(트리밍 대상 중 최후 수단).
    static func assemble(
        cap: Int,
        pinnedExcerpt: String,
        foldedPrefix: String?,
        recentTurns: [StudyChatTurn],
        question: String
    ) -> Result {
        guard cap > 0 else { return .noSend(.capTooSmall) }

        let initial = render(pin: pinnedExcerpt, folded: foldedPrefix, turns: recentTurns, question: question)
        let framingLength = Self.framingLength(
            pinnedExcerpt: pinnedExcerpt, foldedPrefix: foldedPrefix, recentTurns: recentTurns, question: question)

        // §4.2.2 3단계: P ≥ cap이면 배분조차 없이 즉시 실패.
        guard framingLength < cap else { return .noSend(.capTooSmall) }

        let split = budgetSplit(cap: cap, framingLength: framingLength)
        // §4.2.2 6단계: 이번 질문 자리가 0이면 즉시 실패.
        guard split.questionBudget > 0 else { return .noSend(.capTooSmall) }

        if initial.count <= cap {
            return .assembled(initial)
        }

        var pin = pinnedExcerpt
        var folded = foldedPrefix
        var turns = recentTurns

        // 1단계: 접힌 요약 뒤에서 절단(0자까지 — 다 지우면 헤더도 함께 사라진다).
        if let existing = folded {
            let trimmed = trimTailWithMarker(existing, floor: 0, cap: cap) { candidate in
                render(pin: pin, folded: candidate.isEmpty ? nil : candidate, turns: turns, question: question).count
            }
            folded = trimmed.isEmpty ? nil : trimmed
            if render(pin: pin, folded: folded, turns: turns, question: question).count <= cap {
                return .assembled(render(pin: pin, folded: folded, turns: turns, question: question))
            }
        }

        // 2단계: 최근 턴을 오래된 것부터 통째 밀어내되, 흔적 없이 지우지 않고 §4.3의
        // 결정적 접기("역할: 앞 200자…")로 요약을 이어붙인다(AC18 — 대체는 항상 결정적).
        while !turns.isEmpty {
            let dropped = turns.removeFirst()
            let entry = deterministicFold(dropped)
            folded = folded.map { $0 + "\n" + entry } ?? entry
            if render(pin: pin, folded: folded, turns: turns, question: question).count <= cap {
                return .assembled(render(pin: pin, folded: folded, turns: turns, question: question))
            }
        }

        // 3단계: 핀 발췌 뒤에서 절단(floor = min(1,000, pinBudget)까지).
        let pinFloor = min(1000, split.pinBudget)
        pin = trimTailWithMarker(pin, floor: pinFloor, cap: cap) { candidate in
            render(pin: candidate, folded: folded, turns: turns, question: question).count
        }
        if render(pin: pin, folded: folded, turns: turns, question: question).count <= cap {
            return .assembled(render(pin: pin, folded: folded, turns: turns, question: question))
        }

        // 4단계: 이번 질문을 questionBudget자로 절단(최후 수단) — 그래도 넘치면 여기서 끝.
        let trimmedQuestion = trimTailWithMarker(question, floor: split.questionBudget, cap: cap) { candidate in
            render(pin: pin, folded: folded, turns: turns, question: candidate).count
        }

        let finalText = render(pin: pin, folded: folded, turns: turns, question: trimmedQuestion)
        guard finalText.count <= cap else { return .noSend(.cannotFitAfterTrim) }
        return .assembled(finalText)
    }

    // MARK: - 내부 조립·트리밍

    private static func render(pin: String, folded: String?, turns: [StudyChatTurn], question: String) -> String {
        var parts: [String] = []
        if !pin.isEmpty {
            parts.append("[핀 발췌]\n\(pin)")
        }
        if let folded, !folded.isEmpty {
            parts.append("[이전 대화 요약]\n\(folded)")
        }
        if !turns.isEmpty {
            let lines = turns.map { "\(roleLabel($0.role)): \($0.text)" }.joined(separator: "\n")
            parts.append("[대화]\n\(lines)")
        }
        parts.append("[이번 질문]\n\(question)")
        return parts.joined(separator: "\n\n")
    }

    private static func roleLabel(_ role: StudyChatTurn.Role) -> String {
        role == .user ? "사용자" : "도우미"
    }

    /// §4.3 기본 압축 규칙 그대로: `역할: 앞 200자 + "…"`. AI 호출 0. `StudyChatService`(S3)가
    /// 옵트인 AI 요약(§4.3) 실패 시 폴백으로도 그대로 재사용한다(internal — 같은 모듈 재사용).
    static func deterministicFold(_ turn: StudyChatTurn) -> String {
        let prefix = String(turn.text.prefix(200))
        let suffix = turn.text.count > 200 ? "…" : ""
        return "\(roleLabel(turn.role)): \(prefix)\(suffix)"
    }

    /// 뒤에서 최대 100자씩(§4.2.3) 잘라내며 `measure`가 cap 이하를 돌려줄 때까지 시도한다.
    /// 최대 `ceil(원문 길이/100)`회만 시도해 항상 종료를 보장하고(무한루프 없음), 실제로
    /// 잘랐을 때만 말미에 생략 표시(`…(생략)`)를 붙인다 — 그 표시 길이도 `measure`를 통해
    /// 예산 계산에 포함된다.
    private static func trimTailWithMarker(
        _ text: String,
        floor: Int,
        cap: Int,
        measure: (String) -> Int
    ) -> String {
        var current = text
        var hasCut = false
        let maxIterations = Int(ceil(Double(text.count) / 100.0))
        var iterations = 0

        func rendered() -> String {
            hasCut && !current.isEmpty ? current + foldMarker : current
        }

        while measure(rendered()) > cap, current.count > floor, iterations < maxIterations {
            let cutTo = max(floor, current.count - 100)
            current = String(current.prefix(cutTo))
            hasCut = true
            iterations += 1
        }
        return rendered()
    }
}
