import SwiftUI

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// VerdictCardView — 판정 카드 (T-AGO-14)
// ready면 통과 카드, blocked면 변조 경고 카드 + "위험을 알고 실행" 체크박스 게이트.

struct VerdictCardView: View {
    @Bindable var model: PipelineViewModel

    var body: some View {
        if hasEvidence {
            warningCard
        } else if model.phase == .ready {
            successCard
        } else {
            EmptyView()
        }
    }

    /// 변조·서명·spctl 증거 유무. spctl 거부로 idle 복귀해도 카드는 남긴다 (실행 게이트는 blocked에서만).
    private var hasEvidence: Bool {
        !model.verdict.modifiedFiles.isEmpty
            || !model.verdict.codesignNote.isEmpty
            || !model.verdict.spctlNote.isEmpty
    }

    private var warningTitle: String {
        Self.warningTitle(verdict: model.verdict)
    }

    /// 경고 제목 판정 (단위 테스트 가능).
    static func warningTitle(verdict: PipelineVerdict) -> String {
        if !verdict.modifiedFiles.isEmpty {
            return L10n.f("verdict.tamperedTitle", verdict.modifiedFiles.count)
        }
        if !verdict.spctlNote.isEmpty {
            return L10n.s("verdict.devTitle")
        }
        return L10n.s("verdict.brokenTitle")
    }

    // MARK: - 통과

    private var successCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.s("verdict.passTitle"))
                    .font(.headline)
                Text(L10n.s("verdict.passBody"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.verdict.signed {
                    Text(L10n.s("verdict.signed"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.verdict.hadProvenance {
                    Text(L10n.s("verdict.provenance"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.green.opacity(0.12))
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.green.opacity(0.4), lineWidth: 1)
        }
    }

    // MARK: - 경고

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(warningTitle)
                        .font(.headline)
                    Text(L10n.s("verdict.advice"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.verdict.spctlNote.isEmpty {
                        Text(model.verdict.spctlNote)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if model.verdict.hadProvenance {
                        Text(L10n.s("verdict.provenance"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if !model.verdict.modifiedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.verdict.modifiedFiles.prefix(5), id: \.self) { file in
                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if model.verdict.modifiedFiles.count > 5 {
                        Text(L10n.f("verdict.moreFiles", model.verdict.modifiedFiles.count - 5))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 32)
            }
            if model.phase == .blocked {
                Toggle(L10n.s("verdict.acknowledge"), isOn: $model.acknowledged)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.leading, 32)
            } else {
                Text(L10n.s("verdict.cannotRun"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }
        }
        .padding(12)
        .background(.red.opacity(0.1))
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.red.opacity(0.45), lineWidth: 1)
        }
    }
}
