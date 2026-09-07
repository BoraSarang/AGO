import AppKit
import Foundation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// GatePipeline — Process 래퍼, 단계별 실행 + 취소 (T-AGO-10)
// PLAN 2.2 순서: 형식검사 → 조회(ls/xattr) → 제거(xattr -dr) → 검증(codesign) → 평가(spctl) → 확인 후 실행(open)
// 실행은 백그라운드 직렬 큐, 이벤트는 메인 스레드로 전달.

// MARK: - 이벤트 모델 (Sendable)

enum LogKind: Sendable {
    case command
    case output
    case success
    case failure
}

struct LogLine: Identifiable, Sendable {
    let id = UUID()
    let kind: LogKind
    let text: String
}

enum PipelinePhase: Equatable, Sendable {
    case idle
    case inspecting
    case cleaning
    case verifying
    case ready
    /// 변조 의심 — 경고 카드 확인(체크박스) 후에만 실행 가능.
    case blocked
}

/// 검증 단계에서 모은 판정 정보.
struct PipelineVerdict: Equatable, Sendable {
    var modifiedFiles: [String] = []
    var codesignNote: String = ""
    var spctlNote: String = ""
    /// codesign `valid on disk` 여부 (spctl 거부 시 허용 경로 판단용).
    var codesignValid: Bool = false
    static let empty = PipelineVerdict()
}

enum PipelineEvent: Sendable {
    case log(LogLine)
    case phase(PipelinePhase)
    case verdict(PipelineVerdict)
    /// 단계 실패 (타임라인에 실패 지점을 남기기 위해 idle 복귀 전에 발생).
    case failed(at: PipelinePhase)
    /// 실행 결과 (true면 AGO 자동 종료 카운트다운 시작).
    case launched(Bool)
}

// MARK: - 파이프라인

final class GatePipeline: @unchecked Sendable {
    private let onEvent: @MainActor @Sendable (PipelineEvent) -> Void
    private let workQueue = DispatchQueue(label: "com.borasarang.ago.pipeline", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _cancelled = false
    private var currentProcess: Process?

    private var cancelled: Bool {
        get { stateLock.withLock { _cancelled } }
        set { stateLock.withLock { _cancelled = newValue } }
    }

    init(onEvent: @escaping @MainActor @Sendable (PipelineEvent) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - 공개 API

    /// 드롭된 앱의 전체 파이프라인 실행 (조회→제거→검증→평가).
    func inspect(url: URL) {
        cancelled = false
        workQueue.async { [weak self] in
            self?.runInspect(url: url)
        }
    }

    /// 사용자가 실행 버튼을 눌렀을 때만 호출 (자동 실행 금지).
    func launch(url: URL) {
        cancelled = false
        workQueue.async { [weak self] in
            self?.runLaunch(url: url)
        }
    }

    func cancel() {
        cancelled = true
        stateLock.withLock { currentProcess }?.terminate()
    }

    // MARK: - 검사 파이프라인

    private func runInspect(url: URL) {
        emit(.phase(.inspecting))
        emitLog(.command, L10n.f("pipe.start", url.path))
        DebugLogger.info(feature: "GATEOPEN", "검사 시작: \(url.lastPathComponent)")

        // 단계 1: 형식 검사
        do {
            try AppInspector.validateAppBundle(url: url)
        } catch {
            finishWithError(code: (error as? AppError)?.code ?? "E-MAC-VAL-2002",
                            message: error.localizedDescription,
                            at: .inspecting)
            return
        }

        // 단계 2: 조회 (ls + xattr)
        let ls = runProcess("/bin/ls", ["-ld", url.path])
        emitOutput(ls.output)
        guard checkCancelled() else { return }

        let xattrList = runProcess("/usr/bin/xattr", ["-l", url.path])
        emitOutput(xattrList.output)
        guard checkCancelled() else { return }

        if xattrList.exitCode != 0 {
            finishWithError(code: AppError.quarantineInspectFailed("").code,
                            message: AppError.quarantineInspectFailed("").localizedDescription,
                            at: .inspecting)
            return
        }
        let quarantined = AppInspector.hasQuarantine(xattrOutput: xattrList.output)

        // 단계 3: 제거 (quarantine이 있을 때만)
        emit(.phase(.cleaning))
        if quarantined {
            emitLog(.command, "$ xattr -dr com.apple.quarantine \"\(url.path)\"")
            let removed = runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
            emitOutput(removed.output)
            guard checkCancelled() else { return }
            if removed.exitCode != 0 {
                finishWithError(code: AppError.quarantineRemoveFailed("").code,
                                message: AppError.quarantineRemoveFailed("").localizedDescription,
                                at: .cleaning)
                return
            }
            emitLog(.success, L10n.s("pipe.removed"))
            DebugLogger.info(feature: "GATEOPEN", "quarantine 제거 성공")
        } else {
            emitLog(.output, L10n.s("pipe.noQuarantine"))
        }

        // 단계 4: 검증 (codesign)
        emit(.phase(.verifying))
        emitLog(.command, "$ codesign --verify --deep --strict --verbose=4 \"\(url.path)\"")
        let codesign = runProcess("/usr/bin/codesign",
                                  ["--verify", "--deep", "--strict", "--verbose=4", url.path])
        emitOutput(AppInspector.summarizeCodesign(output: codesign.output))
        guard checkCancelled() else { return }

        var verdict = PipelineVerdict()
        switch AppInspector.parseCodesign(output: codesign.output, exitCode: codesign.exitCode) {
        case .valid:
            verdict.codesignValid = true
            emitLog(.success, L10n.s("pipe.signOK"))
            DebugLogger.info(feature: "GATEOPEN", "서명 검증 통과")
        case .tampered(let files):
            verdict.modifiedFiles = files
            verdict.codesignNote = "변조 의심 파일 \(files.count)개"
            emitLog(.failure, L10n.f("pipe.tampered", files.count))
            DebugLogger.error(code: AppError.signatureInvalid([]).code, "변조 의심 파일 \(files.count)개")
        case .broken(let summary):
            verdict.codesignNote = summary
            emitLog(.failure, L10n.f("pipe.signFail", summary))
            DebugLogger.error(code: AppError.signatureInvalid([]).code, summary)
        }

        // 단계 5: 평가 (spctl)
        emitLog(.command, "$ spctl -a -vv \"\(url.path)\"")
        let spctl = runProcess("/usr/sbin/spctl", ["-a", "-vv", url.path])
        emitOutput(spctl.output)
        guard checkCancelled() else { return }

        switch AppInspector.parseSpctl(output: spctl.output, exitCode: spctl.exitCode) {
        case .accepted:
            verdict.spctlNote = "Gatekeeper 통과"
            emitLog(.success, L10n.s("pipe.spctlOK"))
            DebugLogger.info(feature: "GATEOPEN", "spctl 통과")
        case .rejected(let summary):
            // 서명은 정상인데 Gatekeeper만 거부(개발용 서명 등) → 경고 후 허용 경로.
            // 변조 증거가 있으면 기존대로 완전 차단.
            if verdict.codesignValid, verdict.modifiedFiles.isEmpty, verdict.codesignNote.isEmpty {
                verdict.spctlNote = summary
                emit(.verdict(verdict))
                emit(.phase(.blocked))
                emitLog(.failure, L10n.s("pipe.devSig"))
                emitLog(.output, L10n.s("pipe.devHint"))
                DebugLogger.error(code: AppError.gatekeeperRejected("").code, "개발용 서명: \(summary)")
                return
            }
            // 거부돼도 변조 증거는 카드에 남긴다 (VerdictCardView가 idle에서도 표시).
            emit(.verdict(verdict))
            finishWithError(code: AppError.gatekeeperRejected("").code,
                            message: AppError.gatekeeperRejected(summary).localizedDescription,
                            at: .verifying)
            return
        }

        // 판정
        emit(.verdict(verdict))
        if verdict.modifiedFiles.isEmpty, verdict.codesignNote.isEmpty {
            emit(.phase(.ready))
            emitLog(.success, L10n.s("pipe.ready"))
        } else {
            emit(.phase(.blocked))
            emitLog(.failure, L10n.s("pipe.warnTampered"))
        }
        DebugLogger.info(feature: "GATEOPEN", "검사 완료")
    }

    // MARK: - 실행 (사용자 확인 후)

    private func runLaunch(url: URL) {
        emitLog(.command, "$ open \"\(url.path)\"")
        DebugLogger.info(feature: "GATEOPEN", "사용자 확인 후 실행: \(url.lastPathComponent)")
        let opened = NSWorkspace.shared.open(url)
        if opened {
            emitLog(.success, L10n.s("pipe.launched"))
        } else {
            emitLog(.failure, AppError.launchFailed(url.lastPathComponent).localizedDescription)
            DebugLogger.error(code: AppError.launchFailed("").code, url.lastPathComponent)
        }
        emit(.launched(opened))
    }

    // MARK: - 내부 유틸

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        stateLock.withLock { currentProcess = process }
        do {
            try process.run()
        } catch {
            stateLock.withLock { currentProcess = nil }
            return (1, L10n.f("pipe.procFail", error.localizedDescription))
        }
        process.waitUntilExit()
        stateLock.withLock { currentProcess = nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 취소됐으면 true (취소 로그 + idle 복귀 후 종료).
    private func checkCancelled() -> Bool {
        if cancelled {
            emitLog(.output, L10n.s("pipe.cancelled"))
            emit(.phase(.idle))
            DebugLogger.info(feature: "GATEOPEN", "사용자 취소")
            return false
        }
        return true
    }

    private func finishWithError(code: String, message: String, at phase: PipelinePhase) {
        emitLog(.failure, message)
        emit(.failed(at: phase))
        emit(.phase(.idle))
        DebugLogger.error(code: code, message)
    }

    private func emit(_ event: PipelineEvent) {
        // 호출자는 백그라운드 큐. MainActor 작업으로 순서대로 전달한다.
        Task { @MainActor [onEvent] in onEvent(event) }
    }

    private func emitLog(_ kind: LogKind, _ text: String) {
        emit(.log(LogLine(kind: kind, text: text)))
    }

    private func emitOutput(_ output: String) {
        guard !output.isEmpty else { return }
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            emitLog(.output, trimmed)
        }
    }
}
