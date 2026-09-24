import AppKit
import SwiftUI
import UniformTypeIdentifiers

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// DropZoneView — 히어로 드롭존 (T-AGO-12)
// .app / .dmg / .pkg 드래그 수락 + NSOpenPanel 파일 선택 + 아이콘·버전 미리보기.

struct DropZoneView: View {
    @Bindable var model: PipelineViewModel
    @State private var isTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 4])
                )
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary.opacity(0.5))

            if let appURL = model.appURL {
                acceptedView(url: appURL)
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .contentShape(.rect(cornerRadius: 12))
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.space, .return]) { _ in
            openPanel()
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            accept(url: url)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.6 : 1)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .onReceive(NotificationCenter.default.publisher(for: .agoOpenFile)) { _ in
            guard !model.isBusy else { return }
            openPanel()
        }
    }

    // MARK: - 빈 상태

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(L10n.s("drop.title"))
                .font(.headline)
            Text(L10n.s("drop.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button(L10n.s("drop.choose")) { openPanel() }
                    .buttonStyle(.link)
                Button(L10n.s("drop.helpLink")) { model.showingHelp = true }
                    .buttonStyle(.link)
                    .keyboardShortcut("/", modifiers: .command)
                    .help(L10n.s("drop.helpLinkHelp"))
            }
        }
        .padding()
    }

    /// 입력 중이면 종류에 맞는 SF 심볼.
    private var iconName: String {
        guard let url = model.appURL else { return "app.fill" }
        switch AppInspector.dropKind(url: url) {
        case .dmg:
            return "internaldrive"
        case .pkg:
            return "shippingbox.fill"
        case .app, nil:
            return "app.fill"
        }
    }

    // MARK: - 수락 상태

    private func acceptedView(url: URL) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                if let version = appVersion(url: url) {
                    Text(L10n.f("drop.version", version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button(L10n.s("drop.chooseAnother")) { openPanel() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            if !model.isBusy {
                Button {
                    model.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.s("drop.clearHelp"))
            }
        }
        .padding(.horizontal, 16)
    }

    private func appVersion(url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - 수락·선택

    private func accept(url: URL) {
        model.inspect(url: url)
    }

    private func openPanel() {
        DebugLogger.info(feature: "파일선택", "NSOpenPanel 열기")
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .diskImage, .package]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.s("drop.panelMessage")
        if panel.runModal() == .OK, let url = panel.url {
            accept(url: url)
        }
    }
}
