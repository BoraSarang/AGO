import SwiftUI

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// SignPromptView — 서명 확인 다이얼로그용 시트 (T-AGO-21~23)
// 신원 있음 → ContentView의 confirmationDialog 사용. 이 파일은 신원 없음 유도 시트 담당.
// 비번 수집 없음: 수동 입력은 신원 문자열(예: Apple Development: a@b.c (TEAMID))만 받는다.

struct SignIdentitySheet: View {
    @Bindable var model: PipelineViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "signature")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.s("sign.noIdentityTitle"))
                        .font(.headline)
                    Text(L10n.s("sign.noIdentityBody"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.s("sign.guide1"))
                Text(L10n.s("sign.guide2"))
                Text(L10n.s("sign.guide3"))
            }
            .font(.callout)
            TextField(L10n.s("sign.manualPlaceholder"), text: $model.signIdentityInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            HStack {
                Button(L10n.s("sign.openXcode")) { model.openXcode() }
                Button(L10n.s("sign.recheck")) { model.refreshIdentities() }
                Spacer()
                Button(L10n.s("sign.doSign")) { model.decideSign(proceed: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.signIdentityInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && (model.signPrompt?.identities.isEmpty ?? true))
                Button(L10n.s("sign.skip")) {
                    model.decideSign(proceed: false)
                    dismiss()
                }
                .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
