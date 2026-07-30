import Foundation
import Security

/// 지금 실행 중인 이 프로세스가 "이 컴퓨터 전용 고정 인증서"로 서명됐는지, 아니면
/// 예전의 ad-hoc(재빌드·업데이트마다 바뀌는) 서명인지 스스로 판별한다.
///
/// ad-hoc이면 macOS가 다음 재빌드·업데이트 때 이 앱을 "다른 프로그램"으로 인식해
/// 전체 디스크 접근 등 TCC 권한을 다시 요구할 수 있다는 뜻이다(§CLAUDE.md 손쉬운
/// 사용 재발 문제 — 2026-07-30 opus 자문 제안). 예전엔 사용자가 "또 권한이 풀렸다"는
/// 증상만 보고 원인을 몰랐는데, 이제 앱이 스스로 자기 서명 상태를 읽어 알려줄 수 있다.
enum BuildSignatureStatus: Equatable {
    /// 고정 인증서("cmdALL Local Dev" 등) — 재빌드·업데이트해도 정체성이 안 바뀐다.
    case stableIdentity
    /// ad-hoc — 재빌드·업데이트마다 정체성이 바뀌어 TCC 권한이 재발할 수 있다.
    case adHoc
    /// 서명이 없거나 판별에 실패(개발 중 미서명 실행 등).
    case unknown

    /// `codesign -d -r-`가 보여주는 것과 같은 designated requirement 문자열을 분류한다.
    /// 순수 함수 — 테스트 대상(라이브 시스템 호출은 `current()`가 담당하며, 관례대로
    /// 자동 테스트 대상 밖이다).
    static func classify(designatedRequirement text: String) -> BuildSignatureStatus {
        if text.contains("certificate leaf") { return .stableIdentity }
        if text.contains("cdhash") { return .adHoc }
        return .unknown
    }

    /// 지금 실행 중인 프로세스 자신의 서명 상태를 확인한다.
    static func current() -> BuildSignatureStatus {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let codeRef else { return .unknown }
        var staticCodeRef: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, [], &staticCodeRef) == errSecSuccess,
              let staticCodeRef else { return .unknown }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCodeRef, [], &requirement) == errSecSuccess,
              let requirement else { return .unknown }
        var cfString: CFString?
        guard SecRequirementCopyString(requirement, [], &cfString) == errSecSuccess,
              let cfString else { return .unknown }
        return classify(designatedRequirement: cfString as String)
    }
}
