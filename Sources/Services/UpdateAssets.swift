import Foundation

/// 릴리스 자산 URL 조립·체크섬 파싱·오류 문구(전부 순수 — 네트워크·파일시스템 접근 없음).
enum UpdateAssets {
    /// 포크 저장소다. 원작자 저장소(CmdMD)가 아니다.
    static let repository = "learn-slowly/cmd-docu"
    static let assetName = "cmdALL-macos.zip"
    static let sumsName = "SHA256SUMS.txt"

    private static func downloadBase(tag: String) -> String {
        "https://github.com/\(repository)/releases/download/\(tag)"
    }

    static func assetURL(tag: String) -> URL {
        URL(string: "\(downloadBase(tag: tag))/\(assetName)")!
    }

    static func sumsURL(tag: String) -> URL {
        URL(string: "\(downloadBase(tag: tag))/\(sumsName)")!
    }

    /// `shasum -a 256` 형식("<hex>␣␣<파일명>")에서 대상 파일의 해시를 뽑는다.
    /// 경로 접두사(`./dist/…`)·CRLF·대소문자 차이를 허용하고, 없으면 nil.
    static func expectedHash(fromSums text: String, assetName: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let name = (String(fields[fields.count - 1]) as NSString).lastPathComponent
            if name == assetName {
                return String(fields[0]).lowercased()
            }
        }
        return nil
    }

    /// 업데이트 재시작을 표시해 두는 UserDefaults 키. 재시작은 프로세스가 바뀌므로
    /// 메모리로는 전달할 수 없다.
    static let restartMarkerKey = "pendingUpdateRestartVersion"

    /// 업데이트로 재시작한 뒤 첫 실행에서 보여줄 안내(순수).
    ///
    /// 왜 필요한가(2026-07-25 실사고): "지금 다시 시작"을 누르면 앱이 꺼졌다 1초 안에
    /// 켜지고 탭까지 복원돼 화면이 거의 똑같다. 아무 신호가 없어 사용자는 버튼이
    /// 먹통이라 여기고 계속 다시 눌렀다(그때마다 실제로 재시작하고 있었다).
    ///
    /// 표식이 지금 버전과 같을 때만 알린다 — 다르면 교체가 제대로 안 된 것이므로
    /// "업데이트됐다"고 잘못 알리지 않는다.
    static func restartNotice(marker: String?, currentVersion: String) -> String? {
        guard let marker, !marker.isEmpty, marker == currentVersion else { return nil }
        return "cmdALL \(currentVersion)으로 업데이트했습니다."
    }

    /// 사용자에게 보일 한국어 문구. 케이스마다 구분되게 쓴다.
    static func message(for error: UpdateInstallError) -> String {
        switch error {
        case .noWritePermission(let path):
            return "설치 위치에 쓸 수 없습니다(\(path)). 터미널 설치 스크립트를 사용해 주세요."
        case .downloadFailed:
            return "새 버전을 내려받지 못했습니다. 연결을 확인하고 다시 시도해 주세요."
        case .checksumMismatch:
            return "받은 파일 검증에 실패했습니다. 설치하지 않았습니다."
        case .unpackFailed:
            return "받은 파일을 푸는 데 실패했습니다. 설치하지 않았습니다."
        case .bundleVerificationFailed:
            return "받은 앱을 확인하지 못했습니다. 설치하지 않았습니다."
        case .replaceFailed:
            return "설치에 실패했습니다. 기존 버전은 그대로입니다."
        case .replaceFailedBackupLeft(let backupPath):
            return "설치에 실패했고 기존 앱을 되돌리지 못했습니다. 다음 위치에 있습니다: \(backupPath)"
        }
    }
}
