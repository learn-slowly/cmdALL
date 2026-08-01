import Foundation

/// 채점 결과 3종(§3.9). "애매"는 Anki류의 "Hard"에 해당 — 잊지는 않았지만 다음 간격을 크게
/// 늘리지 않는다.
enum ReviewOutcome: String, Equatable {
    case forgot   // 모름
    case unsure   // 애매
    case knew     // 앎
}

/// SM-2 라이트(§3.9) — 순수 함수. 앵커 줄의 현재 상태 + 채점 결과 → 다음 상태.
/// 디스크 IO·시간 흐름 관찰은 전혀 하지 않는다(호출부가 `now`를 넘긴다).
///
/// 스펙 문면에 명시되지 않아 이번 구현에서 보충 해석한 부분 2곳(레고 검수 필요 시 여기부터):
/// 1. **`reps`(연속 성공 횟수)는 "모름"에서 0으로 리셋한다.** "앎"의 "첫 성공 1일·두 번째 3일"
///    특례가 `reps`를 기준으로 하므로, 리셋이 없으면 한 번 잊은 뒤에도 재학습 단계 없이 바로
///    공식 간격으로 건너뛴다 — SM-2 계열의 통상 관행을 따랐다.
/// 2. **"애매"는 `reps`를 건드리지 않는다.** 스펙의 "애매" 공식(`ivl×1.2`)은 `reps`를 전혀
///    참조하지 않아, 연속 성공 집계에도 관여하지 않는 것으로 보수적으로 해석했다.
enum ReviewScheduler {
    static let easeRange: ClosedRange<Double> = 1.30...2.80
    static let maxIntervalDays = 180
    static let dailyNewLimit = 20
    static let dailyReviewLimit = 100

    static func grade(_ state: StudyReviewState, outcome: ReviewOutcome, now: Date = Date()) -> StudyReviewState {
        var ivl = state.interval
        var ease = state.ease
        var reps = state.reps
        var lapses = state.lapses

        switch outcome {
        case .forgot:
            ivl = 1
            ease -= 0.20
            lapses += 1
            reps = 0
        case .unsure:
            ivl = max(1, Int((Double(ivl) * 1.2).rounded()))
            ease -= 0.05
        case .knew:
            switch reps {
            case 0: ivl = 1
            case 1: ivl = 3
            default: ivl = max(1, Int((Double(ivl) * ease).rounded()))
            }
            ease += 0.05
            reps += 1
        }

        ease = min(max(ease, easeRange.lowerBound), easeRange.upperBound)
        ivl = min(ivl, maxIntervalDays)

        let startOfToday = Calendar.current.startOfDay(for: now)
        let due = Calendar.current.date(byAdding: .day, value: ivl, to: startOfToday) ?? startOfToday
        return StudyReviewState(due: due, interval: ivl, ease: ease, reps: reps, lapses: lapses)
    }
}
