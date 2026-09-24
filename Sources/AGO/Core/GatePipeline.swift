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
    /// 서명 확인 대기 (사용자 결정: 서명하기/건너뛰기). T-AGO-21.
    case signing
    case ready
    /// 변조 의심 — 경고 카드 확인(체크박스) 후에만 실행 가능.
    case blocked
}

/// 검증 단계에서 모은 판정 정보.
struct PipelineVerdict: Equatable, Sendable {
    var modifiedFiles: [String] = []
    var codesignNote: String = ""
    var spctlNote: String = ""
    /// 서명 정상 여부 판단 전 발견한 것 (macOS 26+ 출처 속성). 제거됐으면 true.
    /// 타임라인/경고 카드에 "함께 제거됨" 안내로 표시한다.
    var hadProvenance: Bool = false
    /// codesign `valid on disk` 여부 (spctl 거부 시 허용 경로 판단용).
    var codesignValid: Bool = false
    /// 개발자 신원 서명 수행 여부 (서명 전 증거는 위 필드에 그대로 유지).
    var signed: Bool = false
    static let empty = PipelineVerdict()
}

/// 서명 확인 요청 (검증까지의 증거 + 사용 가능한 신원 목록).
struct SignPrompt: Sendable {
    var verdict: PipelineVerdict
    var identities: [String]
}

enum PipelineEvent: Sendable {
    case log(LogLine)
    case phase(PipelinePhase)
    case verdict(PipelineVerdict)
    /// 단계 실패 (타임라인에 실패 지점을 남기기 위해 idle 복귀 전에 발생).
    case failed(at: PipelinePhase)
    /// 실행 결과 (true면 AGO 자동 종료 카운트다운 시작).
    case launched(Bool)
    /// 서명 확인 필요 (UI가 decideSign으로 응답할 때까지 파이프라인 일시 정지).
    case signPrompt(SignPrompt)
    /// 파이프라인이 실제 작업 대상을 확정할 때 (DMG → 내부 .app 추출 경로).
    case target(URL)
}

// MARK: - 파이프라인

final class GatePipeline: @unchecked Sendable {
    private let onEvent: @MainActor @Sendable (PipelineEvent) -> Void
    private let workQueue = DispatchQueue(label: "com.borasarang.ago.pipeline", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _cancelled = false
    private var currentProcess: Process?
    /// 서명 결정 대기용 (signPrompt 발행 후 UI 응답까지).
    private let decisionLock = NSLock()
    private var signDecision: (proceed: Bool, identity: String?)?
    private var signWaiter: DispatchSemaphore?

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
        // 서명 결정 대기 중이면 깨워서 취소 경로로 복귀시킨다.
        decisionLock.withLock { signWaiter }?.signal()
        stateLock.withLock { currentProcess }?.terminate()
    }

    /// UI의 서명 결정 전달 (서명하기=true + 신원, 건너뛰기=false).
    func decideSign(proceed: Bool, identity: String?) {
        decisionLock.withLock { signDecision = (proceed, identity) }
        decisionLock.withLock { signWaiter }?.signal()
    }

    // MARK: - 검사 파이프라인

    private func runInspect(url: URL) {
        emit(.phase(.inspecting))
        emitLog(.command, L10n.f("pipe.start", url.path))
        DebugLogger.info(feature: "GATEOPEN", "검사 시작: \(url.lastPathComponent)")

        // 단계 1: 형식 검사 (app / dmg / pkg)
        do {
            try AppInspector.validateDrop(url: url)
        } catch {
            finishWithError(code: (error as? AppError)?.code ?? "E-MAC-VAL-2002",
                            message: error.localizedDescription,
                            at: .inspecting)
            return
        }
        guard checkCancelled() else { return }

        switch AppInspector.dropKind(url: url) {
        case .dmg:
            runDmgInspect(dmgURL: url)
        case .pkg:
            runPkgInspect(pkgURL: url)
        case .app:
            runAppInspect(appURL: url)
        case nil:
            finishWithError(code: AppError.unsupportedFormat(url.lastPathComponent).code,
                            message: AppError.unsupportedFormat(url.lastPathComponent).localizedDescription,
                            at: .inspecting)
        }
    }

    // MARK: - .app 파이프라인 (기존 단계 유지)

    private func runAppInspect(appURL url: URL) {
        emit(.target(url))

        // 단계 2: 조회 (ls + xattr 재귀)
        // -l(비재귀)은 루트 노드만 보므로 중첩 파일의 quarantine을 놓친다
        // (RoB.app: 루트에는 provenance만, PlugIns/.../libsteam_api.dylib에만 quarantine).
        // 제거는 xattr -dr라 재귀 감지가 곧 재귀 제거로 이어진다.
        let ls = runProcess("/bin/ls", ["-ld", url.path])
        emitOutput(ls.output)
        guard checkCancelled() else { return }

        var xattrOutput = ""
        var xattrExit: Int32 = 1
        let recursive = runProcess("/usr/bin/xattr", ["-lr", url.path])
        if recursive.exitCode == 0 {
            xattrOutput = recursive.output
            xattrExit = 0
        } else {
            // 일부 파일 권한 문제로 재귀 조회가 실패하면 루트만이라도 본다.
            let single = runProcess("/usr/bin/xattr", ["-l", url.path])
            xattrOutput = single.output
            xattrExit = single.exitCode
        }
        guard checkCancelled() else { return }

        if xattrExit != 0 {
            finishWithError(code: AppError.quarantineInspectFailed("").code,
                            message: AppError.quarantineInspectFailed("").localizedDescription,
                            at: .inspecting)
            return
        }
        let quarantined = AppInspector.hasQuarantine(xattrOutput: xattrOutput)
        let provenanced = AppInspector.hasProvenance(xattrOutput: xattrOutput)
        let macled = AppInspector.hasMacl(xattrOutput: xattrOutput)
        emitStampSummary(xattrOutput)
        if provenanced {
            emitLog(.output, L10n.s("pipe.provenanceFound"))
            DebugLogger.info(feature: "GATEOPEN", "macOS 26+ 출처 속성 감지 (com.apple.provenance)")
        }
        if macled {
            emitLog(.output, L10n.s("pipe.maclFound"))
            DebugLogger.info(feature: "GATEOPEN", "권한 귀속 속성 감지 (com.apple.macl)")
        }

        // 단계 3: 제거 (stamp가 있을 때만)
        // - quarantine: 인터넷 다운로드 표식. 무시하면 Gatekeeper 경고.
        // - com.apple.provenance: macOS 26+ 출처 속성. quarantine만 지우고 남으면 실행 시점
        //   재평가(Gatekeeper 확인 창)를 다시 띄우므로 함께 정리한다.
        // - com.apple.macl: 드래그/"다음으로 열기"로 다른 앱이 실행할 때 표식. 남아 있으면
        //   미인정 서명 앱이 TCC(개발자 도구 등) 요청 시점에 커널 정책이 강제종료하므로 정리한다.
        var verdict = PipelineVerdict()
        verdict.hadProvenance = provenanced
        emit(.phase(.cleaning))
        let stamps: [(attribute: String, present: Bool, successKey: String)] = [
            ("com.apple.quarantine", quarantined, "pipe.removed"),
            ("com.apple.provenance", provenanced, "pipe.provenanceRemoved"),
            ("com.apple.macl", macled, "pipe.maclRemoved"),
        ]
        if stamps.contains(where: { $0.present }) {
            for stamp in stamps where stamp.present {
                emitLog(.command, "$ xattr -dr \(stamp.attribute) \"\(url.path)\"")
                let removed = runProcess("/usr/bin/xattr", ["-dr", stamp.attribute, url.path])
                emitOutput(removed.output)
                guard checkCancelled() else { return }
                if removed.exitCode != 0 {
                    finishWithError(code: AppError.quarantineRemoveFailed("").code,
                                    message: AppError.quarantineRemoveFailed("").localizedDescription,
                                    at: .cleaning)
                    return
                }
                emitLog(.success, L10n.s(stamp.successKey))
                DebugLogger.info(feature: "GATEOPEN", "\(stamp.attribute) 제거 성공")
            }
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

        // 단계 4.5: 서명 확인 (사용자 결정, 스킵 가능. T-AGO-21)
        // 서명 전 검증 결과는 verdict에 이미 고정됨 (증거 보존).
        emit(.phase(.signing))
        let identities = AppInspector.parseIdentities(output: AppInspector.findIdentityOutput())
        emitLog(.output, L10n.f("pipe.identities", identities.count))
        emit(.signPrompt(SignPrompt(verdict: verdict, identities: identities)))
        DebugLogger.info(feature: "GATEOPEN", "서명 확인 대기 (신원 \(identities.count)개)")
        guard let decision = awaitSignDecision() else {
            emitLog(.output, L10n.s("pipe.cancelled"))
            emit(.phase(.idle))
            DebugLogger.info(feature: "GATEOPEN", "서명 대기 중 취소")
            return
        }
        if decision.proceed {
            // 서명 실패해도 파이프라인을 끊지 않는다. RoB.app류(중첩 구조 손상)는
            // 재서명이 구조적으로 불가능해도 속성 제거만으로 실행된다.
            if runSign(url: url, identity: decision.identity ?? identities.first ?? "") {
                verdict.signed = true
                // 서명 후 재검증: 서명 유효성만 갱신, 변조 증거(modifiedFiles)는 유지.
                let reverify = runProcess("/usr/bin/codesign",
                                          ["--verify", "--deep", "--strict", "--verbose=4", url.path])
                guard checkCancelled() else { return }
                if case .valid = AppInspector.parseCodesign(output: reverify.output, exitCode: reverify.exitCode) {
                    verdict.codesignValid = true
                }
            } else {
                emitLog(.output, L10n.s("pipe.signSkipped"))
                DebugLogger.info(feature: "GATEOPEN", "서명 실패 — 검증·평가 계속")
            }
        } else {
            emitLog(.output, L10n.s("pipe.signSkipped"))
            DebugLogger.info(feature: "GATEOPEN", "서명 스킵")
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
            // spctl 거부는 더 이상 완전 차단이 아니다.
            // 속성 제거 후에는 Gatekeeper가 실행 시 재평가하지 않고(로컬 실측),
            // macOS 26은 Terminal 위임으로 실행한다. 개발용 서명·중첩 손상(RoB.app) 모두
            // 경고 카드 + 체크박스 게이트(blocked)로 진행한다.
            verdict.spctlNote = summary
            let tamper = !verdict.modifiedFiles.isEmpty || !verdict.codesignNote.isEmpty
            emit(.verdict(verdict))
            emit(.phase(.blocked))
            if AppInspector.spctlAllowGate(codesignValid: verdict.codesignValid,
                                           signed: verdict.signed,
                                           tamperEvidence: tamper) {
                emitLog(.failure, L10n.s("pipe.devSig"))
            } else if tamper {
                emitLog(.failure, L10n.s("pipe.warnTampered"))
            } else {
                emitLog(.failure, summary)
            }
            emitLog(.output, L10n.s("pipe.devHint"))
            DebugLogger.error(code: AppError.gatekeeperRejected("").code, "경고 게이트로 진행: \(summary)")
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

    // MARK: - .dmg 파이프라인 (마운트 → 내부 .app 추출 → 기존 app 파이프라인 연결)

    /// DMG 격리 해제 → 마운트 → 내부 .app 검출 → 임시 위치로 복사 → app 파이프라인 연결.
    private func runDmgInspect(dmgURL: URL) {
        emitLog(.output, L10n.s("pipe.dmgMount"))
        DebugLogger.info(feature: "GATEOPEN", "DMG 마운트 시작: \(dmgURL.lastPathComponent)")

        // DMG 파일 자체의 격리 스탬프를 먼저 정리한다 (마운트 중 내용물 전파 방지).
        emit(.phase(.cleaning))
        let stampAttrs = ["com.apple.quarantine", "com.apple.provenance", "com.apple.macl"]
        for attr in stampAttrs {
            let snap = runProcess("/usr/bin/xattr", ["-l", dmgURL.path]).output
            guard snap.contains(attr) else { continue }
            emitLog(.command, "$ xattr -dr \(attr) \"\(dmgURL.path)\"")
            let removed = runProcess("/usr/bin/xattr", ["-dr", attr, dmgURL.path])
            emitOutput(removed.output)
            guard checkCancelled() else { return }
            if removed.exitCode == 0 {
                emitLog(.success, L10n.s("pipe.removed"))
            }
        }
        guard checkCancelled() else { return }

        // 마운트 (읽기 전용 + 숨김 볼륨)
        emit(.phase(.inspecting))
        emitLog(.command, "$ hdiutil attach -nobrowse -readonly \"\(dmgURL.path)\"")
        let attach = runProcess("/usr/bin/hdiutil",
                                ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path])
        guard checkCancelled() else { return }
        guard attach.exitCode == 0,
              let mountPoint = Self.mountPoint(fromHdiutilPlist: attach.output) else {
            finishWithError(code: AppError.dmgMountFailed(dmgURL.lastPathComponent).code,
                            message: AppError.dmgMountFailed(dmgURL.lastPathComponent).localizedDescription,
                            at: .inspecting)
            return
        }
        emitLog(.success, L10n.f("pipe.dmgMounted", mountPoint))
        DebugLogger.info(feature: "GATEOPEN", "DMG 마운트 성공: \(mountPoint)")

        defer {
            emitLog(.command, "$ hdiutil detach \"\(mountPoint)\"")
            let detach = runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
            if detach.exitCode == 0 {
                emitLog(.success, L10n.s("pipe.dmgDetached"))
            }
            DebugLogger.info(feature: "GATEOPEN", "DMG 분리: \(detach.exitCode == 0 ? "성공" : "실패")")
        }

        // 내부 .app 검출 시도 → 없으면 .pkg 검출 (GOG류 설치 DMG)
        if let appURL = Self.findAppBundle(in: URL(fileURLWithPath: mountPoint)) {
            emitLog(.output, L10n.f("pipe.dmgFoundApp", appURL.lastPathComponent))
            DebugLogger.info(feature: "GATEOPEN", "DMG 내부 앱 발견: \(appURL.lastPathComponent)")

            // 임시 위치로 복사 (DMG는 읽기 전용이라 xattr 제거가 불가능)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("AGO-dmg", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dest = tempDir
                .appendingPathComponent("\(appURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).app")
            emitLog(.command, "$ ditto \"\(appURL.path)\" \"\(dest.path)\"")
            let copy = runProcess("/usr/bin/ditto", [appURL.path, dest.path])
            guard checkCancelled() else { return }
            guard copy.exitCode == 0 else {
                finishWithError(code: AppError.dmgMountFailed(dmgURL.lastPathComponent).code,
                                message: L10n.s("pipe.dmgCopyFail"),
                                at: .inspecting)
                return
            }
            emitLog(.success, L10n.f("pipe.dmgExtracted", dest.lastPathComponent))
            DebugLogger.info(feature: "GATEOPEN", "DMG 앱 추출 완료: \(dest.path)")

            emit(.target(dest))
            runAppInspect(appURL: dest)
            return
        }

        // .app이 없으면 .pkg 폴백 (GOG 설치 DMG: 루트에 PKG만 있는 경우)
        if let pkgURL = Self.findPkg(in: URL(fileURLWithPath: mountPoint)) {
            emitLog(.output, L10n.f("pipe.dmgFoundPkg", pkgURL.lastPathComponent))
            DebugLogger.info(feature: "GATEOPEN", "DMG 내부 패키지 발견: \(pkgURL.lastPathComponent)")

            // 임시 위치로 복사 후 PKG 파이프라인 연결
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("AGO-dmg", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dest = tempDir
                .appendingPathComponent("\(pkgURL.lastPathComponent)-\(UUID().uuidString.prefix(8)).pkg")
            emitLog(.command, "$ ditto \"\(pkgURL.path)\" \"\(dest.path)\"")
            let copy = runProcess("/usr/bin/ditto", [pkgURL.path, dest.path])
            guard checkCancelled() else { return }
            guard copy.exitCode == 0 else {
                finishWithError(code: AppError.dmgMountFailed(dmgURL.lastPathComponent).code,
                                message: L10n.s("pipe.dmgCopyFail"),
                                at: .inspecting)
                return
            }
            emitLog(.success, L10n.f("pipe.dmgExtractedPkg", dest.lastPathComponent))
            DebugLogger.info(feature: "GATEOPEN", "DMG 패키지 추출 완료: \(dest.path)")

            emit(.target(dest))
            runPkgInspect(pkgURL: dest)
            return
        }

        finishWithError(code: AppError.unsupportedFormat(dmgURL.lastPathComponent).code,
                        message: L10n.s("pipe.dmgNoAppOrPkg"),
                        at: .inspecting)
    }

    // MARK: - .pkg 파이프라인 (격리 해제 → 서명 검사 → 설치기 열기)

    /// PKG 격리 해제 → pkgutil/spctl 검사 → open(설치기). 개발자 재서명 없음.
    private func runPkgInspect(pkgURL: URL) {
        var verdict = PipelineVerdict()

        // 격리 스탬프 정리 (설치 시 Gatekeeper 평가 방지용)
        emit(.phase(.cleaning))
        let stampAttrs = [
            ("com.apple.quarantine", "pipe.removed"),
            ("com.apple.provenance", "pipe.provenanceRemoved"),
            ("com.apple.macl", "pipe.maclRemoved"),
        ]
        var anyStamp = false
        for (attr, successKey) in stampAttrs {
            let snap = runProcess("/usr/bin/xattr", ["-l", pkgURL.path]).output
            guard snap.contains(attr) else { continue }
            anyStamp = true
            if attr == "com.apple.provenance" { verdict.hadProvenance = true }
            emitLog(.command, "$ xattr -dr \(attr) \"\(pkgURL.path)\"")
            let removed = runProcess("/usr/bin/xattr", ["-dr", attr, pkgURL.path])
            emitOutput(removed.output)
            guard checkCancelled() else { return }
            if removed.exitCode != 0 {
                finishWithError(code: AppError.quarantineRemoveFailed("").code,
                                message: AppError.quarantineRemoveFailed("").localizedDescription,
                                at: .cleaning)
                return
            }
            emitLog(.success, L10n.s(successKey))
            DebugLogger.info(feature: "GATEOPEN", "PKG \(attr) 제거 성공")
        }
        if !anyStamp {
            emitLog(.output, L10n.s("pipe.noQuarantine"))
        }

        // 서명 검사 (pkgutil)
        emit(.phase(.verifying))
        emitLog(.command, "$ pkgutil --check-signature \"\(pkgURL.path)\"")
        let pkgutil = runProcess("/usr/sbin/pkgutil", ["--check-signature", pkgURL.path])
        emitOutput(pkgutil.output)
        guard checkCancelled() else { return }

        let pkgSig = AppInspector.parsePkgSignature(output: pkgutil.output, exitCode: pkgutil.exitCode)
        switch pkgSig {
        case .signed(let summary):
            verdict.codesignValid = true
            verdict.codesignNote = summary
            emitLog(.success, L10n.f("pipe.pkgSigned", summary))
            DebugLogger.info(feature: "GATEOPEN", "PKG 서명 확인: \(summary)")
        case .unsigned:
            verdict.codesignNote = L10n.s("pipe.pkgUnsigned")
            emitLog(.failure, L10n.s("pipe.pkgUnsigned"))
            DebugLogger.error(code: AppError.signatureInvalid([]).code, "PKG 미서명")
        case .invalid(let summary):
            verdict.codesignNote = summary
            emitLog(.failure, L10n.f("pipe.pkgSignFail", summary))
            DebugLogger.error(code: AppError.signatureInvalid([]).code, "PKG 서명 오류: \(summary)")
        }

        // Gatekeeper 설치 평가 (spctl -t install)
        emitLog(.command, "$ spctl -a -vv -t install \"\(pkgURL.path)\"")
        let spctl = runProcess("/usr/sbin/spctl", ["-a", "-vv", "-t", installAssessmentType, pkgURL.path])
        emitOutput(spctl.output)
        guard checkCancelled() else { return }

        // PKG는 설치 패키지라 앱 서명 단계 없음 → 스킵 로그만 남긴다.
        emit(.phase(.signing))
        emitLog(.output, L10n.s("pipe.pkgNoSign"))

        switch AppInspector.parseSpctl(output: spctl.output, exitCode: spctl.exitCode) {
        case .accepted:
            verdict.spctlNote = "Gatekeeper 설치 평가 통과"
            emitLog(.success, L10n.s("pipe.spctlOK"))
            emit(.verdict(verdict))
            emit(.phase(.ready))
            emitLog(.success, L10n.s("pipe.ready"))
            DebugLogger.info(feature: "GATEOPEN", "PKG 검사 완료 (통과)")
        case .rejected(let summary):
            verdict.spctlNote = summary
            emit(.verdict(verdict))
            emit(.phase(.blocked))
            if verdict.codesignValid {
                emitLog(.failure, L10n.s("pipe.devSig"))
            } else {
                emitLog(.failure, summary)
            }
            emitLog(.output, L10n.s("pipe.devHint"))
            DebugLogger.error(code: AppError.gatekeeperRejected("").code, "PKG 경고 게이트: \(summary)")
        }
    }

    /// spctl 설치 평가용 타입 (`install`). 앱은 기본 `open`을 쓰므로 분리.
    private var installAssessmentType: String { "install" }

    // MARK: - 서명 (사용자 확인 후, T-AGO-21)

    /// signPrompt 발행 후 UI 결정을 기다린다. 취소되면 nil.
    private func awaitSignDecision() -> (proceed: Bool, identity: String?)? {
        let waiter = DispatchSemaphore(value: 0)
        decisionLock.withLock { signWaiter = waiter }
        defer { decisionLock.withLock { signWaiter = nil } }
        while true {
            if waiter.wait(timeout: .now() + 0.2) == .success {
                if cancelled { return nil }
                if let decision = decisionLock.withLock({ signDecision }) {
                    decisionLock.withLock { signDecision = nil }
                    return decision
                }
            } else if cancelled {
                return nil
            }
        }
    }

    /// appex 먼저 → 본체 마지막 순서로 개발자 신원 서명한다. adhoc(`-`) 서명 금지.
    /// 중첩 하나라도 실패하면 본체를 서명하지 않는다 (부분 서명은 부모 봉인을 더 깨뜨린다).
    /// 실패 시 finishWithError 대신 false만 반환 — 호출부가 검증·평가를 계속한다.
    @discardableResult
    private func runSign(url: URL, identity: String) -> Bool {
        guard !identity.isEmpty, identity != "-" else {
            emitLog(.failure, AppError.signingFailed(identity).localizedDescription)
            DebugLogger.error(code: AppError.signingFailed("").code, "서명 신원 없음")
            return false
        }
        let targets = AppInspector.signTargets(appURL: url)
        let nested = targets.dropLast()
        let appBody = targets.last
        for target in nested {
            emitLog(.command, "$ codesign --force -s \"\(identity)\" \"\(target.path)\"")
            let signed = runProcess("/usr/bin/codesign", ["--force", "-s", identity, target.path])
            emitOutput(signed.output)
            guard checkCancelled() else { return false }
            if signed.exitCode != 0 {
                let message = AppError.signingFailed(target.lastPathComponent).localizedDescription
                emitLog(.failure, message)
                DebugLogger.error(code: AppError.signingFailed("").code,
                                  "중첩 서명 실패 — 부분 서명 방지를 위해 중단: \(target.lastPathComponent)")
                return false
            }
        }
        if let appBody {
            emitLog(.command, "$ codesign --force -s \"\(identity)\" \"\(appBody.path)\"")
            let signed = runProcess("/usr/bin/codesign", ["--force", "-s", identity, appBody.path])
            emitOutput(signed.output)
            guard checkCancelled() else { return false }
            if signed.exitCode != 0 {
                let message = AppError.signingFailed(appBody.lastPathComponent).localizedDescription
                emitLog(.failure, message)
                DebugLogger.error(code: AppError.signingFailed("").code,
                                  "본체 서명 실패: \(appBody.lastPathComponent)")
                return false
            }
        }
        emitLog(.success, L10n.f("pipe.signed", identity))
        DebugLogger.info(feature: "GATEOPEN", "서명 완료: \(identity)")
        return true
    }

    /// 재귀 xattr 출력에서 차단 3종 건수만 요약해 로그에 남긴다 (수천 줄 덤프 금지).
    private func emitStampSummary(_ output: String) {
        var counts = (q: 0, p: 0, m: 0)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains("com.apple.quarantine") { counts.q += 1 }
            if line.contains("com.apple.provenance") { counts.p += 1 }
            if line.contains("com.apple.macl") { counts.m += 1 }
        }
        let total = counts.q + counts.p + counts.m
        if total > 0 {
            emitLog(.output, L10n.f("pipe.stampsFound", total))
            DebugLogger.info(feature: "GATEOPEN", "차단 속성 항목: quarantine \(counts.q), provenance \(counts.p), macl \(counts.m)")
        }
    }

    // MARK: - 실행 (사용자 확인 후)

    private func runLaunch(url: URL) {
        emitLog(.command, "$ open \"\(url.path)\"")
        DebugLogger.info(feature: "GATEOPEN", "사용자 확인 후 실행: \(url.lastPathComponent)")

        // 실행 직전 상태를 확정한다. 파이프라인 처리(몇 초) 사이에 macOS가 드래그 맥락으로
        // quarantine/provenance/macl을 다시 붙이면 실행 시점 Gatekeeper 평가에서
        // "Gatekeeper rejection"으로 종료된다(실전 16:41 관측). 성공이 확인된 수동 절차
        // (3속성 제거 직후 open)와 같은 순간을 만들기 위해 직전에 다시 정리한다.
        let snap = runProcess("/usr/bin/xattr", ["-l", url.path]).output
        let present = ["com.apple.quarantine", "com.apple.provenance", "com.apple.macl"]
            .filter { snap.contains($0) }
        DebugLogger.info(feature: "GATEOPEN", "실행 직전 속성: \(present.isEmpty ? "없음" : present.joined(separator: ","))")
        for attr in ["com.apple.quarantine", "com.apple.provenance", "com.apple.macl"] {
            if snap.contains(attr) {
                _ = runProcess("/usr/bin/xattr", ["-dr", attr, url.path])
            }
        }

        // 실행 방법 (실측 검증 순):
        // ① Terminal.app 위임 — AGO 같은 미인정 앱이 직접 열면 macOS 26이
        //    "신뢰 없는 책임 프로세스"로 보고 차단하므로(실측 반복), 정품
        //    Terminal.app의 자식 셸에서 열어 사용자 세션 책임 체인으로 우회.
        //    최초 1회 "AGO가 터미널을 제어하려고 합니다" TCC 허용 필요.
        // ② 직접 open — 가장 빠르지만 미인정 런처는 차단됨.
        // ③ launchctl asuser — launchd 사용자 도메인 경유 예비책.
        // 각 단계는 실제 프로세스 생존으로 판정한다.
        let uid = runProcess("/usr/bin/id", ["-u"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = url.path.replacingOccurrences(of: "'", with: "'\\''")
        // AppleScript: tell Terminal to do script — 셸 명령을 Terminal 자식에서 실행
        let termScript = "tell application \"Terminal\" to do script \"xattr -dr com.apple.quarantine '\(quoted)' && open -g '\(quoted)' && exit\""
        let attempts: [(String, [String], TimeInterval)] = [
            ("/usr/bin/osascript", ["-e", termScript], 3.0),   // ① Terminal 위임 (검증됨)
            ("/usr/bin/open", ["-g", url.path], 1.8),           // ② 직접 open
            ("/bin/launchctl", ["asuser", uid, "/usr/bin/open", "-g", url.path], 1.8), // ③ asuser
        ]
        for (prog, args, wait) in attempts {
            guard launchAndAlive(prog: prog, args, match: url.path, wait: wait) else { continue }
            if prog == "/usr/bin/osascript" {
                DebugLogger.info(feature: "GATEOPEN", "Terminal 위임 실행 성공")
            }
            emitLog(.success, L10n.s("pipe.launched"))
            emit(.launched(true))
            return
        }
        emitLog(.failure, AppError.launchFailed(url.lastPathComponent).localizedDescription)
        DebugLogger.error(code: AppError.launchFailed("").code, url.lastPathComponent)
        emit(.launched(false))
    }

    // 실행 후 짧게 대기해 프로세스가 살아 있는지(Gatekeeper 살해 여부) 판정한다.
    // Terminal 위임은 do script가 즉시 반환되므로 실제 open은 백그라운드에서
    // LaunchServices → Gatekeeper 평가를 거쳐 뒤늦게 뜬다. wait 후 1회 확인,
    // 실패 시 1.5초 간격 최대 3회 재시도해 false negative를 줄인다 (실측 17:50
    // 관측: 앱은 떴으나 3초 1회 판정만으로는 miss → 전체 실패로 오판).
    private func launchAndAlive(prog: String, _ args: [String], match: String, wait: TimeInterval = 1.8) -> Bool {
        let (rc, out) = runProcess(prog, args)
        _ = out
        DebugLogger.info(feature: "GATEOPEN", "\(prog) rc=\(rc)")
        guard rc == 0 else { return false }
        Thread.sleep(forTimeInterval: wait)
        for attempt in 0..<4 {
            // macOS 26: /bin/pgrep 없음 — /usr/bin/pgrep. 경로 오류면 runProcess가
            // 파일 미존재로 예외를 반환해 생존 판정이 항상 false가 된다 (실측 17:50
            // 관측: 앱은 떴으나 "실패"로 오판된 원인).
            let (alive, _) = runProcess("/usr/bin/pgrep", ["-f", match])
            if alive == 0 {
                if attempt > 0 {
                    DebugLogger.info(feature: "GATEOPEN", "생존 확인 \(attempt)회 재시도 후 성공")
                }
                return true
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 1.5) }
        }
        DebugLogger.info(feature: "GATEOPEN", "생존 확인 실패 (\(prog))")
        return false
    }

    // MARK: - 내부 유틸

    /// `hdiutil attach -plist` 출력에서 첫 번째 마운트 포인트를 찾는다.
    static func mountPoint(fromHdiutilPlist plistOutput: String) -> String? {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        // mount-point 키가 있는 엔트리 우선, 없으면 dev-entry + mount-point 병합.
        for entity in entities {
            if let mp = entity["mount-point"] as? String, !mp.isEmpty {
                return mp
            }
        }
        return nil
    }

    /// 볼륨에서 가장 얕은 `.app` 번들을 찾는다 (최대 `maxDepth`단계 재귀).
    static func findAppBundle(in directory: URL, maxDepth: Int = 4) -> URL? {
        findBundle(in: directory, pathExtension: "app", maxDepth: maxDepth)
    }

    /// 볼륨에서 가장 얕은 `.pkg` 파일을 찾는다 (`.app` 없을 때 폴백용).
    static func findPkg(in directory: URL, maxDepth: Int = 4) -> URL? {
        findBundle(in: directory, pathExtension: "pkg", maxDepth: maxDepth)
    }

    /// 지정한 확장자를 가진 가장 얕은 파일/번들을 재귀 탐색한다.
    private static func findBundle(in directory: URL, pathExtension: String, maxDepth: Int) -> URL? {
        guard maxDepth >= 0 else { return nil }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return nil }

        // 같은 깊이에서는 알파벳 순으로 결정적 선택
        let matches = items
            .filter { $0.pathExtension.lowercased() == pathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let first = matches.first { return first }

        guard maxDepth > 0 else { return nil }
        for folder in items {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // .app 번들 내부는 더 파지 않는다 (PlugIns 등은 대상이 아님)
            guard isDir, folder.pathExtension.lowercased() != "app" else { continue }
            if let nested = findBundle(in: folder, pathExtension: pathExtension, maxDepth: maxDepth - 1) {
                return nested
            }
        }
        return nil
    }

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
        // waitUntilExit() 후 readDataToEndOfFile()는 출력이 pipe 버퍼(64KB)를 넘으면
        // 데드락한다. xattr -lr(수천 줄)·codesign --verbose=4에서 실제 멈춤 원인.
        // 읽기를 먼저 끝내고(EOF=자식 종료) 그 다음 wait.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stateLock.withLock { currentProcess = nil }
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
