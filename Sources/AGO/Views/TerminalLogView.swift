import AppKit
import SwiftUI

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// TerminalLogView — 터미널 카드 (T-AGO-13)
// SF Mono 로그, 명령/성공/에러 색 구분, 자동 스크롤 + 복사 + 여러 줄 선택.

struct TerminalLogView: View {
    var lines: [LogLine]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if lines.isEmpty {
                            Text(L10n.s("log.empty"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        }
                        ForEach(lines) { line in
                            row(line)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
                .onChange(of: lines.count) {
                    // 레이아웃 이후에 스크롤해야 끝까지 감 (LazyVStack+동기 호출은 중간에 멈춤).
                    if let last = lines.last {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.s("log.title"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
            if copied {
                Label(L10n.s("log.copied"), systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Button {
                    copy()
                } label: {
                    Label(L10n.s("log.copy"), systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.s("log.copyHelp"))
                .disabled(lines.isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func row(_ line: LogLine) -> some View {
        Text(displayText(line))
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(12 * 0.4)
            .foregroundStyle(color(line.kind))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayText(_ line: LogLine) -> String {
        switch line.kind {
        case .command: line.text
        case .output: line.text
        case .success: "✓ \(line.text)"
        case .failure: "✗ \(line.text)"
        }
    }

    private func color(_ kind: LogKind) -> Color {
        switch kind {
        case .command: .primary
        case .output: .secondary
        case .success: .green
        case .failure: .red
        }
    }

    private func copy() {
        let text = lines.map { displayText($0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DebugLogger.info(feature: "로그복사", "로그 \(lines.count)줄 복사됨")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
