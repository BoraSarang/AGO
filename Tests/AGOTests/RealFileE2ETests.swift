import Foundation
import Testing
@testable import AGO

// 실제 Downloads 파일 기반 E2E — 파일이 없으면 스킵 (CI/다른 기기)
// 파일이 있으면 격리 해제 → 마운트/추출(또는 PKG 검사) → 최종 phase까지 확인.

@Suite("실전 E2E (Downloads)")
struct RealFileE2ETests {
    private static let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)

    private static let smallDmg = downloads.appendingPathComponent("train_valley_2_enUS_1_9_4_.dmg")
    private static let largeDmg = downloads.appendingPathComponent("Raiders.of.Blackveil.v2026.09.17.MacOS-U2B.dmg")
    private static let samplePkg = downloads.appendingPathComponent("dlc_train_valley_2___editor_s_bulletin_enUS_1_9_4_.pkg")

    @Test("작은 DMG (GOG 설치) — 마운트·PKG 검출·PKG 파이프라인 연결")
    func e2eSmallDmgPkgFallback() async throws {
        try Self.require(Self.smallDmg)
        let result = await Self.runToTerminal(url: Self.smallDmg, timeout: .seconds(180))
        // train_valley DMG는 루트에 .pkg만 있음 (.app 없음) → PKG 폴백 경로
        #expect(result.target?.pathExtension == "pkg")
        #expect(result.phase == PipelinePhase.ready || result.phase == PipelinePhase.blocked)
        #expect(result.sawTarget)
        #expect(result.mountLog)
        #expect(result.extractLog)
        #expect(result.pkgSignedLog || result.pkgUnsignedLog || result.spctlLog)
        if let target = result.target, target.path.contains("AGO-dmg") {
            try? FileManager.default.removeItem(at: target)
        }
    }

    @Test("큰 DMG (RoB) — 마운트·앱 추출·앱 파이프라인 연결")
    func e2eLargeDmgApp() async throws {
        try Self.require(Self.largeDmg)
        let result = await Self.runToTerminal(url: Self.largeDmg, timeout: .seconds(600))
        // RoB DMG는 루트에 RoB.app 있음 → 앱 파이프라인 경로
        #expect(result.target?.pathExtension == "app")
        #expect(result.phase == PipelinePhase.ready || result.phase == PipelinePhase.blocked)
        #expect(result.sawTarget)
        #expect(result.mountLog)
        #expect(result.extractLog)
        if let target = result.target, target.path.contains("AGO-dmg") {
            try? FileManager.default.removeItem(at: target)
        }
    }

    @Test("샘플 PKG — 서명 검사 후 ready/blocked")
    func e2eSamplePkg() async throws {
        try Self.require(Self.samplePkg)
        let result = await Self.runToTerminal(url: Self.samplePkg, timeout: .seconds(60))
        #expect(result.phase == PipelinePhase.ready || result.phase == PipelinePhase.blocked)
        #expect(result.pkgSignedLog || result.pkgUnsignedLog || result.spctlLog)
    }

    // MARK: - 헬퍼

    private static func require(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw E2ESkip("파일 없음: \(url.lastPathComponent)")
        }
    }

    private static func runToTerminal(url: URL, timeout: Duration) async -> E2EResult {
        let state = await MainActor.run { E2EState() }
        let pipeline = GatePipeline { event in
            Task { @MainActor in state.handle(event) }
        }
        pipeline.inspect(url: url)

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let terminal = await MainActor.run { state.terminalPhase() }
            if terminal != nil {
                return await MainActor.run { state.snapshot() }
            }
            let needsSign = await MainActor.run { state.takeNeedsSignDecision() }
            if needsSign {
                pipeline.decideSign(proceed: false, identity: nil)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        pipeline.cancel()
        return await MainActor.run { state.snapshot() }
    }

    private struct E2ESkip: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { "SKIP: \(message)" }
    }

    private struct E2EResult {
        var phase: PipelinePhase = .idle
        var target: URL?
        var sawTarget = false
        var mountLog = false
        var extractLog = false
        var pkgSignedLog = false
        var pkgUnsignedLog = false
        var spctlLog = false
        var lines: [String] = []
        var sawSignPrompt = false
    }

    @MainActor
    private final class E2EState {
        private var phase: PipelinePhase = .idle
        private var result = E2EResult()
        private var needsSignDecision = false
        private var terminalSeen = false

        func handle(_ event: PipelineEvent) {
            switch event {
            case .phase(let p):
                phase = p
                result.phase = p
                if p == .ready || p == .blocked {
                    terminalSeen = true
                }
            case .target(let url):
                result.sawTarget = true
                result.target = url
            case .signPrompt:
                result.sawSignPrompt = true
                needsSignDecision = true
            case .log(let line):
                result.lines.append(line.text)
                let t = line.text
                if t.contains("hdiutil") && t.contains("attach") { result.mountLog = true }
                if t.contains("ditto") || t.contains("추출") || t.lowercased().contains("extracted") {
                    result.extractLog = true
                }
                if t.contains("pkgutil") && (t.contains("서명") || t.lowercased().contains("sign")) {
                    result.pkgSignedLog = true
                }
                if t.lowercased().contains("no signature") || t.contains("미서명") {
                    result.pkgUnsignedLog = true
                }
                if t.contains("spctl") { result.spctlLog = true }
            default:
                break
            }
        }

        func terminalPhase() -> PipelinePhase? {
            terminalSeen ? phase : nil
        }

        func takeNeedsSignDecision() -> Bool {
            guard needsSignDecision else { return false }
            needsSignDecision = false
            return true
        }

        func snapshot() -> E2EResult { result }
    }
}
