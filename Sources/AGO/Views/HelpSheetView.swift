import AppKit
import SwiftUI

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// HelpSheetView — 도움말 시트 (T-AGO-15). ⌘/ 로 표시.

struct HelpSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.s("help.title"))
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(L10n.s("help.close")) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(title: L10n.s("help.s1t"), body: L10n.s("help.s1b"))
                    section(title: L10n.s("help.s2t"), body: L10n.s("help.s2b"))
                    section(title: L10n.s("help.s3t"), body: L10n.s("help.s3b"))
                    section(title: L10n.s("help.s4t"), body: L10n.s("help.s4b"))
                }
            }
            Divider()
            HStack(spacing: 4) {
                Text(L10n.s("help.madeBy"))
                Text("·")
                Button(L10n.s("help.contact")) {
                    if let url = URL(string: "mailto:leeborasarang@gmail.com") {
                        NSWorkspace.shared.open(url)
                    }
                    DebugLogger.info(feature: "문의", "도움말에서 문의 메일 열기")
                }
                Text("·")
                Link("GitHub", destination: URL(string: "https://github.com/BoraSarang/AGO")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.link)
        }
        .padding(20)
        .frame(width: 420, height: 380)
        .onAppear {
            DebugLogger.info(feature: "도움말", "도움말 시트 표시")
        }
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
