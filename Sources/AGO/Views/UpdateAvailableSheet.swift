import AppKit
import SwiftUI

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// UpdateAvailableSheet — 새 버전 알림 시트 + 릴리스 노트 마크다운 렌더링
// 렌더링은 가이드 검증 방식: 줄 단위 블록 분류 + inlineOnlyPreservingWhitespace + run별 폰트.
// (AttributedString 전체 구문 파싱은 블록이 한 덩어리로 붙고, Text.font()는 볼드를 덮어쓴다.)

struct UpdateAvailableSheet: View {
    let update: UpdateModel
    @Environment(\.dismiss) private var dismiss

    private var release: GitHubRelease? { update.availableRelease }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.s("update.sheetTitle"))
                        .font(.headline)
                    if let release {
                        Text("\(L10n.f("update.current", appVersion)) → \(L10n.f("update.latest", release.tagName))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
            }

            Text(L10n.s("update.notesTitle"))
                .font(.subheadline)
                .fontWeight(.semibold)
            ScrollView {
                ReleaseNotesView(markdown: release?.body ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Text(L10n.s("update.methodBody"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.s("update.later")) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(L10n.s("update.download")) {
                    if let release, let url = URL(string: release.htmlURL) {
                        NSWorkspace.shared.open(url)
                        DebugLogger.info(feature: "업데이트", "릴리스 페이지 열기: \(release.tagName)")
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 440)
        .onAppear {
            DebugLogger.info(feature: "업데이트", "업데이트 시트 표시")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

// MARK: - 릴리스 노트 마크다운 블록 렌더링

/// 줄 단위 블록 분류 + 인라인만 해석해 개행을 보존하는 렌더러 (가이드 검증 방식).
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    private var blocks: [NoteBlock] {
        var result: [NoteBlock] = []
        var inCode = false
        var codeBuffer: [String] = []
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer = []
                }
                inCode.toggle()
                continue
            }
            if inCode {
                codeBuffer.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append(.spacer)
                continue
            }
            if trimmed.hasPrefix("#") {
                let content = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                result.append(.heading(String(content)))
                continue
            }
            if let bullet = trimmed.first(where: { $0 == "-" || $0 == "*" || $0 == "•" }),
               trimmed.count > 1, trimmed[trimmed.index(after: trimmed.startIndex)] == " " {
                let content = String(trimmed.dropFirst(2))
                result.append(.bullet(content))
                continue
            }
            if trimmed.hasPrefix(">") {
                result.append(.quote(String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))))
                continue
            }
            if let dotRange = trimmed.range(of: ". "),
               trimmed.prefix(while: { $0.isNumber }).count > 0,
               dotRange.lowerBound == trimmed.index(trimmed.startIndex, offsetBy: trimmed.prefix(while: { $0.isNumber }).count) {
                result.append(.numbered(String(trimmed[dotRange.upperBound...])))
                continue
            }
            result.append(.paragraph(trimmed))
        }
        if inCode, !codeBuffer.isEmpty {
            result.append(.code(codeBuffer.joined(separator: "\n")))
        }
        return result
    }

    private enum NoteBlock {
        case heading(String)
        case bullet(String)
        case numbered(String)
        case quote(String)
        case code(String)
        case paragraph(String)
        case spacer
    }

    @ViewBuilder
    private func blockView(_ block: NoteBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.styledInline(text, size: 13, bold: true))
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(Self.styledInline(text, size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let text):
            Text(Self.styledInline(text, size: 12))
                .fixedSize(horizontal: false, vertical: true)
        case .quote(let text):
            Text(Self.styledInline(text, size: 12))
                .foregroundStyle(.secondary)
                .italic()
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2)
                }
        case .code(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        case .paragraph(let text):
            Text(Self.styledInline(text, size: 12))
                .fixedSize(horizontal: false, vertical: true)
        case .spacer:
            Spacer()
                .frame(height: 4)
        }
    }

    /// 인라인(굵기·기울임·코드)만 해석하고 블록 개행은 SwiftUI Text가 담당.
    /// 폰트는 run마다 직접 기록한다 — View의 .font()는 볼드 특성을 덮어쓴다 (가이드 실패 3번).
    static func styledInline(_ s: String, size: CGFloat, bold: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attr = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in attr.runs {
            var font = Font.system(size: size)
            let intent = run.inlinePresentationIntent
            if bold || intent?.contains(.stronglyEmphasized) == true { font = font.bold() }
            if intent?.contains(.emphasized) == true { font = font.italic() }
            if intent?.contains(.code) == true {
                font = Font.system(size: size, design: .monospaced)
            }
            attr[run.range].font = font
        }
        return attr
    }
}
