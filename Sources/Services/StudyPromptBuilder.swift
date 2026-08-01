import Foundation

/// 카드·문제 생성 지시문(순수, `RagPromptBuilder` 전례와 같은 형태). 청크 본문(위치 태그가
/// 이미 붙은 `StudyChunk.body`)은 여기서 만들지 않는다 — `ClaudeService.ask(prompt:context:)`의
/// `context`(stdin)로 그대로 보내고, 이 타입이 만드는 문자열은 `prompt`(-p 인자) 몫이다
/// (§4.2.5 "프롬프트 본체는 -p 인자라 청크 예산에 미포함"). 출력 문법·상한은 O1~O3 그대로.
enum StudyPromptBuilder {

    /// - Parameter count: 이 청크에서 요청할 카드 개수 상한(`StudyService`가 §O6 `ceil(N/C)`로
    ///   계산해 넘긴다) — 내용이 부족하면 이보다 적게 나와도 된다.
    /// - Parameter extraInstructions: 사용자 템플릿의 추가 지시(레고 2026-08-01 요청) — 빈 값이면
    ///   기존 지시문 그대로. 형식(O1~O3)은 이 값과 무관하게 항상 고정 — 뒤에 "추가 지시"로만 붙는다.
    static func cardPrompt(count: Int, extraInstructions: String = "") -> String {
        let n = max(1, count)
        let base = """
        당신은 학습 자료로 한국어 정리 카드를 만드는 조수다.
        아래 stdin으로 주어진 교재 내용만 근거로 삼아라. 원문에 없는 내용은 절대 지어내지 마라.
        교재 각 부분 앞에는 [[p12]]([몇 쪽])·[[l345]]([몇 줄])·[[?]](위치 불명) 같은 위치 표시가 붙어 있다.
        카드마다 그 표시를 그대로(고치지 말고) 복사해 근거 줄에 써라.

        아래 형식으로 최대 \(n)개까지 만들어라(다룰 만한 주제가 적으면 더 적어도 된다):
        ### [카드] 제목
        - 핵심 내용 1
        - 핵심 내용 2
        - 핵심 내용 3(있으면)
        > 근거: [[위치표시]] "원문에서 그대로 옮긴 문장"

        규칙: 제목은 80자 이내, 불릿은 최대 3개까지만(그 이상은 새 카드로) 각 120자 이내,
        근거 발췌는 200자 이내로 원문 그대로 옮겨라. 근거는 카드마다 정확히 1개.
        """
        return Self.appendingExtraInstructions(base, extraInstructions)
    }

    /// - Parameter count: 이 청크에서 요청할 문제 개수 상한(§O6). 내용이 부족하면 더 적어도 된다.
    /// - Parameter extraInstructions: 사용자 템플릿의 추가 지시(레고 2026-08-01 요청) — 빈 값이면
    ///   기존 지시문 그대로. 형식(O1~O3)은 이 값과 무관하게 항상 고정 — 뒤에 "추가 지시"로만 붙는다.
    static func quizPrompt(count: Int, extraInstructions: String = "") -> String {
        let n = max(1, count)
        let base = """
        당신은 학습 자료로 한국어 연습 문제를 만드는 조수다.
        아래 stdin으로 주어진 교재 내용만 근거로 삼아라. 원문에 없는 내용은 절대 지어내지 마라.
        교재 각 부분 앞에는 [[p12]]([몇 쪽])·[[l345]]([몇 줄])·[[?]](위치 불명) 같은 위치 표시가 붙어 있다.
        문제마다 그 표시를 그대로(고치지 말고) 복사해 근거 줄에 써라.

        아래 형식으로 최대 \(n)개까지 만들어라(다룰 만한 내용이 적으면 더 적어도 된다). 기본은
        4지선다(type: mcq)를 써라 — 내용상 더 어울리면 type을 "OX"나 "단답" 같은 다른 값으로
        쓰고 보기 줄은 생략해도 된다(단, mcq는 보기 3~5개 필수):
        ### [문제 1] 문항 요지
        type: mcq
        Q: 질문 본문
        1) 보기 A
        2) 보기 B
        3) 보기 C
        4) 보기 D
        A: 정답 번호
        해설: 왜 그 답인지
        > 근거: [[위치표시]] "원문에서 그대로 옮긴 문장"

        규칙: 제목은 80자 이내, 해설은 600자 이내, 근거 발췌는 200자 이내로 원문 그대로 옮겨라.
        근거는 문제마다 정확히 1개.
        """
        return Self.appendingExtraInstructions(base, extraInstructions)
    }

    /// 사용자 템플릿(§StudyTemplate)의 자유 지시문을 고정 지시문 뒤에 덧붙인다. 빈 값(또는
    /// 공백만)이면 그대로 — 기본 동작(레고 2026-08-01 "기본 설정은 그대로 두되")과 100% 동일.
    private static func appendingExtraInstructions(_ base: String, _ extraInstructions: String) -> String {
        let trimmed = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base + "\n\n추가 지시(사용자 템플릿): \(trimmed)"
    }
}
