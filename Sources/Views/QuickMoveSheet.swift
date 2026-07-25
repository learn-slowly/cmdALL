import SwiftUI

/// "빠른 이동…" 시트 — 등록된 목적지 폴더 클릭 시 즉시 이동(스펙 §4.3).
/// 실제 이동은 F1b가 만든 `performBatchMove`(로그+되돌리기 포함)를 그대로 쓴다.
struct QuickMoveSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("빠른 이동")
                    .font(.headline)
                Spacer()
                Text("\(appState.quickMoveTargets.count)개 항목")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if appState.quickMoveFolders.isEmpty {
                ContentUnavailableView {
                    Label("등록된 폴더가 없습니다", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("폴더에서 우클릭 → \"빠른 이동 목록에 추가\"로 등록하세요")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(appState.quickMoveFolders) { entry in
                    Button {
                        move(to: entry.url)
                    } label: {
                        Label(entry.url.lastPathComponent, systemImage: "folder")
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Button("다른 폴더로 이동…") {
                    let targets = appState.quickMoveTargets
                    dismiss()
                    appState.promptBatchMove(urls: targets)
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
            }
            .padding()
        }
        .frame(width: 340, height: 360)
    }

    private func move(to destination: URL) {
        let targets = appState.quickMoveTargets
        dismiss()
        Task { @MainActor in
            await appState.performBatchMove(urls: targets, to: destination)
        }
    }
}
