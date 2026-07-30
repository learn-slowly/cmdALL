import Carbon.HIToolbox
import Foundation

/// 전역 단축키(⌘⇧M 빠른 캡처·⌘⇧8 전역 검색)를 macOS Carbon HotKey API로 등록한다.
///
/// 예전엔 `NSEvent.addGlobalMonitorForEvents`로 시스템 전체 키 입력을 엿듣는 방식을 썼는데,
/// 이건 "손쉬운 사용(Accessibility)" 신뢰가 반드시 있어야 동작한다 — 그리고 이 신뢰는 앱을
/// 재빌드/업데이트할 때 서명이 바뀌면(§CLAUDE.md 손쉬운 사용 재발 문제) 매번 깨졌고, 레고님이
/// 가장 자주 겪은 증상이 바로 이 전역 단축키 먹통이었다(2026-07-27 이후 반복).
///
/// `RegisterEventHotKey`는 "이 키 조합 하나만 나에게 알려달라"고 WindowServer에 등록하는
/// 전용 API라 Accessibility 신뢰가 전혀 필요 없다(HotKey·MASShortcut·KeyboardShortcuts 같은
/// 서드파티 라이브러리도 내부적으로 이 API를 감싼 것 — Carbon이지만 macOS 최신 버전까지
/// 계속 지원되는 표준 API다). 또한 이 API는 자기 앱이 최전방일 때도 정상 동작하므로, 예전에
/// 그 경우를 보완하려 따로 두던 로컬 모니터(`globalSearchLocalMonitor`)도 필요 없어진다.
///
/// 이 변경으로 손쉬운 사용 권한이 완전히 불필요해지는 건 아니다 — 전체 디스크 접근 등
/// 다른 TCC 권한은 여전히 별도로 존재하고, 그건 이 컴퓨터 전용 고정 인증서(§CLAUDE.md)로
/// 대응한다. 두 대응은 서로 다른 문제를 각각 막는 것이라 함께 유지한다.
@MainActor
final class GlobalHotKeyRegistrar {
    enum HotKey: UInt32 {
        case quickCapture = 1   // ⌘⇧M
        case globalSearch = 2   // ⌘⇧8
    }

    /// 이 앱만의 임의 4바이트 식별자("cmda"의 ASCII 코드 조합). 다른 앱의 핫키 등록과
    /// 섞이지 않게 하는 용도일 뿐 의미론적 값은 아니다.
    private static let signature: OSType = 0x636D_6461

    private var refs: [HotKey: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private let onHotKey: (HotKey) -> Void

    init(onHotKey: @escaping (HotKey) -> Void) {
        self.onHotKey = onHotKey
    }

    /// ⌘⇧M·⌘⇧8을 등록한다. 여러 번 호출해도 안전(이미 등록된 건 건너뛴다).
    func register() {
        installHandlerIfNeeded()
        add(.quickCapture, keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey))
        add(.globalSearch, keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | shiftKey))
    }

    /// 앱 종료 시(또는 재등록 전) 핫키·이벤트 핸들러를 전부 해제한다.
    func unregisterAll() {
        for (_, ref) in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID), nil,
                                            MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let hotKey = HotKey(rawValue: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let registrar = Unmanaged<GlobalHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            registrar.onHotKey(hotKey)
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
    }

    private func add(_ hotKey: HotKey, keyCode: UInt32, modifiers: UInt32) {
        guard refs[hotKey] == nil else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: hotKey.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[hotKey] = ref
        }
    }
}
