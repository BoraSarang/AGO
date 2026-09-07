import SwiftUI

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// PipelineTimelineView — 확인 → 제거 → 검증 → 실행 4단계 타임라인 (T-AGO-14)
// 성공은 체크, 실패 지점은 빨간 X로 남긴다 (idle 복귀 후에도 failed가 유지됨).

enum TimelineStepState: Equatable, Sendable {
    case pending
    case active
    case done
    case failed
}

struct PipelineTimelineView: View {
    var phase: PipelinePhase
    var failed: PipelinePhase?

    enum Step: Int, CaseIterable {
        case check, clean, verify, run
        var title: String {
            switch self {
            case .check: L10n.s("step.check")
            case .clean: L10n.s("step.clean")
            case .verify: L10n.s("step.verify")
            case .run: L10n.s("step.run")
            }
        }
    }

    /// 단계 상태 판정 (단위 테스트 가능).
    static func state(step: Step, phase: PipelinePhase, failed: PipelinePhase?) -> TimelineStepState {
        if phase == .ready || phase == .blocked {
            return .done
        }
        if let failed, let failIndex = stepIndex(phase: failed) {
            if step.rawValue < failIndex { return .done }
            if step.rawValue == failIndex { return .failed }
            return .pending
        }
        guard let active = stepIndex(phase: phase) else { return .pending }
        if step.rawValue < active { return .done }
        if step.rawValue == active { return .active }
        return .pending
    }

    /// 진행 중 단계의 인덱스. idle·ready·blocked는 nil (위에서 별도 처리).
    static func stepIndex(phase: PipelinePhase) -> Int? {
        switch phase {
        case .inspecting: 0
        case .cleaning: 1
        case .verifying: 2
        case .idle, .ready, .blocked: nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                stepView(step)
                if step != .run {
                    connector(after: step.rawValue)
                }
            }
        }
    }

    private func stepView(_ step: Step) -> some View {
        let st = Self.state(step: step, phase: phase, failed: failed)
        return HStack(spacing: 6) {
            Image(systemName: icon(st, step: step))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color(st, step: step))
                .contentTransition(.symbolEffect(.replace))
            Text(step.title)
                .font(.caption)
                .fontWeight(st == .active ? .semibold : .regular)
                .foregroundStyle(st == .pending ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
    }

    private func connector(after index: Int) -> some View {
        let reached: Bool = {
            if phase == .ready || phase == .blocked { return true }
            if let failed, let fi = Self.stepIndex(phase: failed) { return index < fi }
            if let active = Self.stepIndex(phase: phase) { return index < active }
            return false
        }()
        return Rectangle()
            .fill(reached ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25))
            .frame(height: 1.5)
            .frame(maxWidth: 24)
    }

    private func icon(_ st: TimelineStepState, step: Step) -> String {
        switch st {
        case .done:
            if phase == .blocked, step == .run { return "exclamationmark.triangle.fill" }
            return "checkmark.circle.fill"
        case .active:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "xmark.circle.fill"
        case .pending:
            return "circle"
        }
    }

    private func color(_ st: TimelineStepState, step: Step) -> Color {
        switch st {
        case .done:
            if phase == .blocked, step == .run { return .orange }
            return .green
        case .active:
            return .accentColor
        case .failed:
            return .red
        case .pending:
            return .secondary.opacity(0.5)
        }
    }
}
