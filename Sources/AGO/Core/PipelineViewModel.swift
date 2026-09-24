import AppKit
import Foundation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// PipelineViewModel — 파이프라인 이벤트를 받아 UI 상태를 들고 있는 단일 진실 (T-AGO-10~14)
// MainActor 격리. GatePipeline은 실행마다 새로 만든다.

@MainActor @Observable
final class PipelineViewModel {
    var phase: PipelinePhase = .idle
    /// 마지막 실패 지점 (idle 복귀 후에도 타임라인에 남긴다. 새 검사·초기화 시 해제).
    var failedPhase: PipelinePhase?
    var lines: [LogLine] = []
    var verdict: PipelineVerdict = .empty
    var appURL: URL?
    var acknowledged = false
    var showingHelp = false
    /// 서명 확인 요청 (nil이면 미표시). T-AGO-21.
    var signPrompt: SignPrompt?
    /// 서명 건너뛰기 체크박스 (기본 체크). 체크 시 확인 다이얼로그 없이 자동 스킵.
    var skipSigning = true
    /// 신원 있음 → 확인 다이얼로그, 없음 → 유도 시트.
    var showingSignConfirm = false
    var showingSignHelp = false
    /// 수동 입력 신원 (비어 있으면 목록 첫 번째 사용).
    var signIdentityInput = ""
    /// 자동 종료 카운트다운 (초 단위, nil이면 미작동).
    private(set) var quitCountdown: Int?
    private var countdownTask: Task<Void, Never>?

    private var pipeline: GatePipeline?

    var isBusy: Bool {
        phase == .inspecting || phase == .cleaning || phase == .verifying || phase == .signing
    }

    var canRun: Bool {
        phase == .ready || (phase == .blocked && acknowledged)
    }

    func inspect(url: URL) {
        pipeline?.cancel()
        stopQuitCountdown()
        acknowledged = false
        verdict = .empty
        failedPhase = nil
        lines = []
        signPrompt = nil
        showingSignConfirm = false
        showingSignHelp = false
        signIdentityInput = ""
        do {
            try AppInspector.validateDrop(url: url)
        } catch {
            appURL = nil
            let message = error.localizedDescription
            lines = [LogLine(kind: .failure, text: message)]
            DebugLogger.error(code: (error as? AppError)?.code ?? "E-MAC-VAL-2002", message)
            return
        }
        appURL = url
        DebugLogger.info(feature: "파일검사", "검사 요청: \(url.lastPathComponent)")
        let pipeline = GatePipeline(onEvent: { [weak self] event in
            guard let self else { return }
            self.apply(event)
        })
        self.pipeline = pipeline
        pipeline.inspect(url: url)
    }

    func run() {
        guard let appURL, canRun else { return }
        DebugLogger.info(feature: "앱실행", "실행 버튼: \(appURL.lastPathComponent)")
        pipeline?.launch(url: appURL)
    }

    func cancel() {
        pipeline?.cancel()
    }

    func reset() {
        pipeline?.cancel()
        pipeline = nil
        stopQuitCountdown()
        appURL = nil
        acknowledged = false
        verdict = .empty
        failedPhase = nil
        lines = []
        phase = .idle
        signPrompt = nil
        showingSignConfirm = false
        showingSignHelp = false
        signIdentityInput = ""
        DebugLogger.info(feature: "파일검사", "초기화")
    }

    // MARK: - 서명 결정 (T-AGO-21~23)

    /// 서명하기(true)/건너뛰기(false)를 파이프라인에 전달한다.
    func decideSign(proceed: Bool) {
        let manual = signIdentityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = manual.isEmpty ? signPrompt?.identities.first : manual
        DebugLogger.info(feature: "서명확인", proceed ? "서명 진행: \(identity ?? "(신원 없음)")" : "서명 스킵")
        pipeline?.decideSign(proceed: proceed, identity: identity)
        signPrompt = nil
        showingSignConfirm = false
        showingSignHelp = false
    }

    /// 미등록 유도 시트에서 Xcode를 연다.
    func openXcode() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            NSWorkspace.shared.open(url)
            DebugLogger.info(feature: "서명안내", "Xcode 열기")
        } else {
            lines.append(LogLine(kind: .failure, text: L10n.s("sign.noXcode")))
            DebugLogger.error(code: AppError.signingFailed("").code, "Xcode 없음")
        }
    }

    /// 유도 시트에서 신원 목록을 다시 읽는다.
    func refreshIdentities() {
        Task.detached { [weak self] in
            let identities = AppInspector.parseIdentities(output: AppInspector.findIdentityOutput())
            await MainActor.run { [weak self] in
                guard let self, self.signPrompt != nil else { return }
                self.signPrompt?.identities = identities
                DebugLogger.info(feature: "서명안내", "신원 다시 확인: \(identities.count)개")
                if !identities.isEmpty {
                    self.showingSignHelp = false
                    self.showingSignConfirm = true
                }
            }
        }
    }

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .log(let line):
            lines.append(line)
            if lines.count > 500 {
                lines.removeFirst(lines.count - 500)
            }
        case .phase(let newPhase):
            phase = newPhase
        case .verdict(let newVerdict):
            verdict = newVerdict
        case .failed(let at):
            failedPhase = at
        case .launched(let opened):
            if opened {
                startQuitCountdown()
            }
        case .signPrompt(let prompt):
            signPrompt = prompt
            if prompt.identities.isEmpty {
                showingSignHelp = true
                DebugLogger.info(feature: "서명확인", "신원 없음 — 유도 시트 표시")
            } else if skipSigning {
                // 체크 박스 기본 ON: 확인 없이 서명을 건너뛴다.
                DebugLogger.info(feature: "서명확인", "자동 건너뛰기 (체크박스 ON)")
                lines.append(LogLine(kind: .output, text: L10n.s("pipe.signAutoSkipped")))
                decideSign(proceed: false)
            } else {
                showingSignConfirm = true
                DebugLogger.info(feature: "서명확인", "서명 확인 다이얼로그 표시")
            }
        case .target(let target):
            // DMG 추출 후 내부 .app 경로로 갱신 (실행·버전 미리보기 대상).
            appURL = target
            DebugLogger.info(feature: "파일검사", "작업 대상 확정: \(target.lastPathComponent)")
        }
    }

    // MARK: - 자동 종료 카운트다운

    /// 실행 성공 후 5초 카운트다운 시작.
    func startQuitCountdown() {
        stopQuitCountdown()
        quitCountdown = 5
        DebugLogger.info(feature: "앱실행", "5초 후 자동 종료 카운트다운 시작")
        countdownTask = Task { @MainActor [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tickQuitCountdown()
            }
        }
    }

    /// 1초 틱. 0이 되면 앱 종료. 테스트에서 직접 호출 가능 (5번째 틱은 실제 종료되므로 호출 금지).
    func tickQuitCountdown() {
        guard let current = quitCountdown else { return }
        if current <= 1 {
            quitCountdown = nil
            countdownTask = nil
            DebugLogger.info(feature: "앱실행", "자동 종료")
            NSApplication.shared.terminate(nil)
        } else {
            quitCountdown = current - 1
        }
    }

    private func stopQuitCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        quitCountdown = nil
    }
}
