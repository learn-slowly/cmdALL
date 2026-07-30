import Foundation
import AppKit

extension AppState {

    // MARK: - Update checking

    /// Compares two version strings ("v1.4.4" / "1.4.4") component-wise.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Checks the GitHub Releases API for a newer version. Silent checks are
    /// throttled to once every 6h; `userInitiated` checks always run and report.
    func checkForUpdates(userInitiated: Bool = false) {
        guard !isCheckingForUpdate else { return }

        let throttleKey = "lastUpdateCheck"
        if !userInitiated {
            let last = UserDefaults.standard.double(forKey: throttleKey)
            if Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        }

        isCheckingForUpdate = true
        Task { @MainActor in
            defer { isCheckingForUpdate = false }
            let current = AppInfo.version
            do {
                // 포크 저장소의 릴리스를 본다(원본 CmdMD가 아님). 포크에 릴리스가
                // 없으면 업데이트를 권하지 않는다 — 원본 릴리스로 덮어쓰는 사고 방지.
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/learn-slowly/cmdALL/releases/latest")!)
                request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10

                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if userInitiated { showToast("Couldn't check for updates") }
                    return
                }

                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
                latestTag = tag
                latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                updateURL = URL(string: (json["html_url"] as? String) ?? "https://github.com/learn-slowly/cmdALL/releases/latest")

                if Self.isVersion(tag, newerThan: current) {
                    updateAvailable = true
                    if userInitiated { showToast("Update available: \(latestVersion ?? tag)") }
                } else {
                    updateAvailable = false
                    if userInitiated { showToast("You're on the latest version (\(current))") }
                }
            } catch {
                if userInitiated { showToast("Couldn't check for updates") }
            }
        }
    }

    /// 설치 절차의 주입 지점. 기본값은 실제 `UpdateInstaller`.
    typealias UpdateInstallWork = @Sendable (_ tag: String, _ version: String, _ bundle: URL,
                                             _ report: @Sendable @escaping (UpdateProgress) -> Void) async throws -> Void

    /// 알약·About 버튼이 부르는 진입점. 받기→검증→교체까지 하고 재시작 대기 상태로 둔다.
    ///
    /// `installToken`이 필요한 이유: 진행률 보고는 설치기(actor)에서 오므로 MainActor로
    /// 건너뛰어야 하는데, 그 사이 설치가 끝나면 늦게 도착한 보고가 `.readyToRelaunch`를
    /// 덮어써 "설치 중"으로 되돌린다. 토큰이 다르면 무시한다.
    @MainActor
    func startUpdateInstall(perform: UpdateInstallWork? = nil) async {
        guard !updateProgress.isBusy else { return }
        guard let tag = latestTag, let version = latestVersion else { return }

        let bundle = Bundle.main.bundleURL
        let token = UUID()
        installToken = token
        updateProgress = .downloading(fraction: 0)

        let work: UpdateInstallWork = perform ?? { tag, version, bundle, report in
            let installer = UpdateInstaller()
            try await installer.install(tag: tag, expectedVersion: version,
                                        targetBundle: bundle, onProgress: report)
        }

        do {
            try await work(tag, version, bundle) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.installToken == token else { return }
                    self.updateProgress = progress
                }
            }
            installToken = nil          // 이후 도착하는 보고는 버린다
            updateProgress = .readyToRelaunch
        } catch let error as UpdateInstallError {
            installToken = nil
            updateProgress = .failed(UpdateAssets.message(for: error))
        } catch {
            installToken = nil
            updateProgress = .failed(UpdateAssets.message(for: .downloadFailed(error.localizedDescription)))
        }
    }

    /// "나중에"·오류 닫기 — 알약(updateAvailable)은 그대로 둔다.
    func dismissUpdateProgress() {
        updateProgress = .idle
    }

    /// 종료 시 재실행하도록 예약만 한다. 실제 실행은 applicationWillTerminate가 한다 —
    /// 저장 확인에서 취소하면 종료가 취소되므로, 미리 띄우면 인스턴스가 두 개가 된다.
    func armRelaunch(bundleURL: URL) {
        pendingRelaunchBundleURL = bundleURL
    }

    /// "지금 다시 시작". 저장 안 된 문서 확인은 기존 applicationShouldTerminate가 맡는다.
    ///
    /// 재시작은 프로세스가 바뀌므로, 다음 실행에서 알릴 수 있게 표식을 남긴다 —
    /// 재시작이 1초 안에 끝나고 탭까지 복원돼 화면이 똑같아 보이는 탓에 사용자가
    /// 버튼을 먹통으로 여기고 계속 다시 누른 실사고가 있었다(2026-07-25).
    func relaunchForUpdate() {
        if let version = latestVersion {
            UserDefaults.standard.set(version, forKey: UpdateAssets.restartMarkerKey)
        }
        armRelaunch(bundleURL: Bundle.main.bundleURL)

        // ★ 시트가 떠 있으면 macOS가 앱 종료를 막는다. About 창이 시트라서, 거기서
        // "지금 다시 시작"을 누르면 terminate가 조용히 무시돼 버튼이 먹통으로 보였다
        // (프로세스 밖 최소 재현으로 확정: 시트 표시 중 terminate → 반환만 되고 종료 안 됨;
        // 시트를 닫고 0.4초 뒤 terminate → shouldTerminate·willTerminate 거쳐 정상 종료).
        // 그래서 먼저 닫고, 실제로 사라진 뒤에 종료한다.
        showAbout = false
        // 빠른 보기는 오버레이라 시트와 달리 종료를 막지 않는다. 그래도 종료
        // 직전에 미리보기 자원(QLPreviewView)을 정리해 두려고 함께 닫는다
        // (재실행은 새 프로세스라 상태가 어차피 초기화되지만, 정리는 지금 한다).
        closeQuickLook()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }

        // 그래도 종료가 시작되지 않으면(다른 시트·모달이 떠 있는 등) 먹통처럼 보이지 않게
        // 알리고 예약을 거둔다 — 예약이 남으면 나중에 앱을 끌 때 유령처럼 다시 켜진다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.pendingRelaunchBundleURL != nil else { return }
            self.pendingRelaunchBundleURL = nil
            UserDefaults.standard.removeObject(forKey: UpdateAssets.restartMarkerKey)
            self.showToast("다시 시작하지 못했습니다. 앱을 껐다 켜면 새 버전이 적용됩니다.")
        }
    }

    /// 실행 직후 1회 — 업데이트로 재시작한 것이면 알린다. 표식은 어느 경우든 지운다.
    func announceUpdateRestartIfNeeded() {
        let defaults = UserDefaults.standard
        let marker = defaults.string(forKey: UpdateAssets.restartMarkerKey)
        guard marker != nil else { return }
        defaults.removeObject(forKey: UpdateAssets.restartMarkerKey)
        if let notice = UpdateAssets.restartNotice(marker: marker, currentVersion: AppInfo.version) {
            showToast(notice)
        }
    }

    /// 종료가 취소됐을 때 재시작 예약을 거둔다.
    ///
    /// 실사고(2026-07-25): "지금 다시 시작"을 눌렀는데 저장 확인 대화상자에서 종료가
    /// 취소되면 앱은 그대로 남는데 예약만 살아 있었다. 사용자에겐 버튼이 "먹통"으로
    /// 보이고, 나중에 직접 앱을 끄면 유령처럼 다시 켜졌다. 예약을 거두고 이유를 알린다.
    /// 설치 자체는 이미 끝났으므로 `updateProgress`는 건드리지 않는다 — 다시 누를 수 있다.
    func cancelPendingRelaunch() {
        guard pendingRelaunchBundleURL != nil else { return }   // 평범한 종료 취소는 조용히
        pendingRelaunchBundleURL = nil
        showToast("다시 시작하지 않았습니다 — 저장 확인에서 취소했습니다.")
    }

    /// Copies the current document's filesystem path to the clipboard (⌥⌘C).
    func copyCurrentFilePath() {
        guard let url = currentDocument?.fileURL else {
            showToast("No file path — save the document first")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showToast("Path copied")
    }
}
