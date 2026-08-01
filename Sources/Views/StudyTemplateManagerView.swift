import SwiftUI

/// 카드·문제 생성 템플릿 관리 시트(레고 2026-08-01 요청 — "정리카드나 연습문제 템플릿을 만들거나
/// 수정"). 여기서 만드는 건 기본 지시문 뒤에 덧붙는 "추가 지시"뿐 — 카드·문제의 필수 형식(제목·
/// 근거 표시 등)은 `StudyPromptBuilder`가 항상 고정으로 붙여서 파싱이 깨지지 않는다.
struct StudyTemplateManagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("학습 템플릿 관리").font(.headline)
                Spacer()
                Button("닫기") { dismiss() }
            }
            Text("정리 카드·연습 문제를 만들 때 기본 지시문 뒤에 덧붙일 나만의 지시문을 만들고 고칠 수 있습니다(예: \"쉬운 말로, 초등학생도 알아듣게\"). 카드·문제의 기본 형식(제목·근거 표시 등)은 항상 그대로 유지됩니다.")
                .font(.caption).foregroundStyle(.secondary)

            if state.settings.studyTemplates.isEmpty {
                Text("아직 만든 템플릿이 없습니다. 아래 '템플릿 추가'로 시작하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            List {
                ForEach($state.settings.studyTemplates) { $template in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("템플릿 이름", text: $template.name)
                            Picker("", selection: $template.kind) {
                                Text("카드").tag(StudyItemKind.card)
                                Text("문제").tag(StudyItemKind.question)
                            }
                            .labelsHidden()
                            .frame(width: 90)
                        }
                        TextField("추가 지시(예: 쉬운 말로, 초등학생도 알아듣게)",
                                  text: $template.instructions, axis: .vertical)
                            .lineLimit(2...4)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { idx in
                    state.settings.studyTemplates.remove(atOffsets: idx)
                    appState.saveUserData()
                }
            }

            HStack {
                Button("템플릿 추가") {
                    state.settings.studyTemplates.append(
                        StudyTemplate(name: "새 템플릿", kind: appState.studyGenerationKind))
                    appState.saveUserData()
                }
                Spacer()
                Button("저장") { appState.saveUserData() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 480, height: 420)
    }
}
