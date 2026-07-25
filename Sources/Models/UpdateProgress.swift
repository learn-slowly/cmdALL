import Foundation

/// 앱 내 업데이트 설치 진행 상태(스펙 §5.3). UI는 이 값만 보고 그린다.
enum UpdateProgress: Equatable {
    case idle
    case downloading(fraction: Double)
    case verifying
    case installing
    /// 교체까지 끝나고 재시작 대기. "나중에"를 골라도 이미 새 버전이 설치돼 있다.
    case readyToRelaunch
    /// 사용자에게 보일 한국어 사유.
    case failed(String)

    /// 진행 중이면 새 설치를 시작하지 않는다.
    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing: return true
        case .idle, .readyToRelaunch, .failed: return false
        }
    }
}

/// 설치 실패 사유(스펙 §7). 문구 변환은 `UpdateAssets.message(for:)`가 맡는다.
enum UpdateInstallError: Error, Equatable {
    case noWritePermission(path: String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case bundleVerificationFailed(String)
    /// 교체에 실패했지만 기존 앱은 제자리로 원복됐다.
    case replaceFailed(String)
    /// 교체·원복 모두 실패 — 기존 앱이 backupPath에 남아 있다.
    case replaceFailedBackupLeft(backupPath: String)
}
