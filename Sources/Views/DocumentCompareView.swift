import SwiftUI

/// 두 파일 비교 시트(Docufinder 격차 3번). 나란히(2단) 대신 위키 인제스트가 쓰는 기존
/// 통합(unified) diff 컴포넌트를 재사용 — `WikiDiffListView`(added=초록, removed=빨강
/// 취소선). `AppState.requestCompare`가 비동기로 두 파일 본문을 뽑아 diff를 채운다.
struct DocumentCompareView: View {
    @Environment(AppState.self) private var appState
    let request: CompareRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("문서 비교").font(.headline)
                    HStack(spacing: 6) {
                        Text(request.urlA.lastPathComponent)
                        Image(systemName: "arrow.right")
                        Text(request.urlB.lastPathComponent)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appState.compareRequest = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            Group {
                if appState.compareBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("비교하는 중…").foregroundStyle(.secondary)
                    }
                } else if let err = appState.compareError {
                    Text(err).foregroundStyle(.red).textSelection(.enabled)
                } else if appState.compareDiffLines.allSatisfy({ $0.kind == .same }) {
                    Text("두 파일 내용이 같습니다.").foregroundStyle(.secondary)
                } else {
                    WikiDiffListView(lines: appState.compareDiffLines)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: 640, height: 480)
    }
}
