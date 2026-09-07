import AppKit
import SwiftUI

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// AGO 앱 셸 — 풀커스텀 콘텐츠 + 네이티브 크롬 (T-AGO-12~15)
// 크롬: unified 툴바 · 트래픽라이트 유지 · ⌘O/⌘T/⌘/ · 종료 시 앱 종료.

final class AGOAppDelegate: NSObject, NSApplicationDelegate {
    private let startUptime = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        DebugLogger.perf(String(format: "Cold start → didFinishLaunching %.0fms (예산 1500ms)", elapsedMs))
        DebugLogger.info(feature: "앱기동", "AGO 시작")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AGOApp: App {
    @NSApplicationDelegateAdaptor(AGOAppDelegate.self) private var appDelegate
    @AppStorage("agoPinned") private var pinned = true
    @State private var model = PipelineViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, pinned: $pinned)
                .onReceive(NotificationCenter.default.publisher(for: .agoShowHelp)) { _ in
                    model.showingHelp = true
                }
        }
        .defaultSize(width: 520, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L10n.s("menu.open")) {
                    NotificationCenter.default.post(name: .agoOpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(L10n.s("help.title")) {
                    NotificationCenter.default.post(name: .agoShowHelp, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: PipelineViewModel
    @Binding var pinned: Bool

    var body: some View {
        VStack(spacing: 12) {
            PipelineTimelineView(phase: model.phase, failed: model.failedPhase)
                .padding(.top, 4)
            DropZoneView(model: model)
            TerminalLogView(lines: model.lines)
                .frame(minHeight: 120)
            VerdictCardView(model: model)
            runRow
            bottomBar
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pinned.toggle()
                    if let window = NSApp.keyWindow {
                        window.level = pinned ? .floating : .normal
                    }
                    DebugLogger.info(feature: "핀", pinned ? "항상 위 켜짐" : "항상 위 꺼짐")
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin.slash")
                }
                .keyboardShortcut("t", modifiers: .command)
                .help(pinned ? "항상 위 끄기 (Cmd+T)" : "항상 위 켜기 (Cmd+T)")
            }
        }
        .onAppear {
            DebugLogger.info(feature: "메인화면", "ContentView 표시")
            if pinned {
                DispatchQueue.main.async {
                    NSApp.keyWindow?.level = .floating
                }
            }
        }
        .sheet(isPresented: $model.showingHelp) {
            HelpSheetView()
        }
    }

    // MARK: - 실행 행

    private var runRow: some View {
        HStack(spacing: 10) {
            if let remaining = model.quitCountdown {
                Label(L10n.f("app.quitting", remaining), systemImage: "hourglass")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    .contentTransition(.numericText(value: Double(remaining)))
            } else             if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                Button(L10n.s("app.cancel")) { model.cancel() }
                    .buttonStyle(.link)
                Spacer()
            } else {
                Button {
                    model.run()
                } label: {
                    Label(L10n.s("app.run"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canRun)
                .help(model.phase == .blocked && !model.acknowledged
                      ? L10n.s("app.runHelpBlocked")
                      : L10n.s("app.runHelpReady"))
            }
        }
    }

    // MARK: - 하단

    private var bottomBar: some View {
        HStack {
            Button(L10n.s("app.help")) { model.showingHelp = true }
                .buttonStyle(.link)
                .keyboardShortcut("/", modifiers: .command)
            Text("v\(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            contactLinks
            Button(L10n.s("app.quit")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    private var contactLinks: some View {
        HStack(spacing: 4) {
            Button(L10n.s("app.contact")) {
                if let url = URL(string: "mailto:leeborasarang@gmail.com") {
                    NSWorkspace.shared.open(url)
                }
                DebugLogger.info(feature: "문의", "문의 메일 열기")
            }
            Text("·")
            Link("GitHub", destination: githubURL)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.link)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - 제작 정보

    /// GitHub 저장소 (T-AGO-19 릴리스 후 개설됨).
    private var githubURL: URL {
        URL(string: "https://github.com/BoraSarang/AGO")!
    }
}

extension Notification.Name {
    static let agoShowHelp = Notification.Name("agoShowHelp")
    static let agoOpenFile = Notification.Name("agoOpenFile")
}
