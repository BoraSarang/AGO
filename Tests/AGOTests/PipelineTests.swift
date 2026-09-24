import Foundation
import Testing
@testable import AGO

// 파이프라인 단위 테스트 — 파싱·상태머신·에러코드 (T-AGO-16)

@Suite("AppInspector 파싱")
struct InspectorTests {
    @Test("quarantine 속성 감지")
    func detectsQuarantine() {
        let withQ = "com.apple.quarantine: 0083;abc;Chrome;\n"
        #expect(AppInspector.hasQuarantine(xattrOutput: withQ))
        #expect(!AppInspector.hasQuarantine(xattrOutput: ""))
    }

    @Test("provenance 속성 감지 — quarantine과 독립")
    func detectsProvenance() {
        let both = "com.apple.provenance: f63842ce318d\ncom.apple.quarantine: 0083;abc;\n"
        #expect(AppInspector.hasProvenance(xattrOutput: both))
        #expect(AppInspector.hasQuarantine(xattrOutput: both))
        let onlyQ = "com.apple.quarantine: 0083;abc;\n"
        #expect(!AppInspector.hasProvenance(xattrOutput: onlyQ))
        #expect(AppInspector.hasQuarantine(xattrOutput: onlyQ))
        let onlyP = "com.apple.provenance: f63842ce318d\n"
        #expect(AppInspector.hasProvenance(xattrOutput: onlyP))
        #expect(!AppInspector.hasQuarantine(xattrOutput: onlyP))
        #expect(!AppInspector.hasProvenance(xattrOutput: ""))
    }

    @Test("macl 속성 감지 — 드래그 귀속 표식")
    func detectsMacl() {
        let withM = "com.apple.macl: \\x01DL...\ncom.apple.provenance: f63842ce318d\n"
        #expect(AppInspector.hasMacl(xattrOutput: withM))
        #expect(!AppInspector.hasMacl(xattrOutput: "com.apple.provenance: x\n"))
        #expect(!AppInspector.hasMacl(xattrOutput: ""))
    }

    @Test("codesign 정상 판정")
    func codesignValid() {
        let out = "/Applications/Foo.app: valid on disk\n/Applications/Foo.app: satisfies its Designated Requirement"
        #expect(AppInspector.parseCodesign(output: out, exitCode: 0) == .valid)
    }

    @Test("codesign 변조 파일 추출")
    func codesignTampered() {
        let out = """
        /tmp/Bad.app: valid on disk
        file added: /tmp/Bad.app/Contents/MacOS/evil
        file modified: /tmp/Bad.app/Contents/Info.plist
        """
        let result = AppInspector.parseCodesign(output: out, exitCode: 0)
        #expect(result == .tampered([
            "/tmp/Bad.app/Contents/MacOS/evil",
            "/tmp/Bad.app/Contents/Info.plist",
        ]))
    }

    @Test("codesign 미서명 파손 판정")
    func codesignBroken() {
        let out = "/tmp/Plain.app: code object is not signed at all"
        let result = AppInspector.parseCodesign(output: out, exitCode: 1)
        if case .broken(let summary) = result {
            #expect(summary.contains("not signed"))
        } else {
            Issue.record("broken 판정이어야 함: \(result)")
        }
    }

    @Test("spctl 통과·거부 판정")
    func spctlVerdicts() {
        let ok = "/Applications/Foo.app: accepted\nsource=Notarized Developer ID"
        #expect(AppInspector.parseSpctl(output: ok, exitCode: 0) == .accepted)
        let ng = "/tmp/Bad.app: rejected\nsource=no usable signature"
        let result = AppInspector.parseSpctl(output: ng, exitCode: 3)
        if case .rejected(let summary) = result {
            #expect(summary.contains("rejected"))
        } else {
            Issue.record("rejected 판정이어야 함: \(result)")
        }
    }

    @Test("codesign 잡음 요약 (Keep It 사례)")
    func codesignSummary() {
        let out = """
        --prepared:/tmp/K.app/Contents/PlugIns/A.appex
        --validated:/tmp/K.app/Contents/PlugIns/A.appex
        /tmp/K.app: a sealed resource is missing or invalid
        file added: /tmp/K.app/Contents/Resources/libCon.dylib
        file modified: /tmp/K.app/Contents/Frameworks/R.framework
        """
        let summary = AppInspector.summarizeCodesign(output: out)
        #expect(!summary.contains("--prepared:"))
        #expect(!summary.contains("--validated:"))
        #expect(summary.contains("file added: /tmp/K.app/Contents/Resources/libCon.dylib"))
        #expect(summary.contains("2개 구성요소 검증됨"))
    }
    @Test(".app 아닌 경로는 거부")
    func rejectsNonApp() throws {
        #expect(throws: AppError.self) {
            try AppInspector.validateAppBundle(url: URL(fileURLWithPath: "/tmp/foo.dmg"))
        }
        do {
            try AppInspector.validateAppBundle(url: URL(fileURLWithPath: "/tmp/ghost.app"))
            Issue.record("번들 구조 없는 .app은 거부되어야 함")
        } catch let error as AppError {
            #expect(error.code == "E-MAC-VAL-2002")
        }
    }

    @Test("find-identity 신원 추출 (PageKit 사례)")
    func parsesIdentities() {
        let out = """
          1) 76811B50FF3F9015B9E287FC6829806E1D42B9DB "Apple Development: a@b.c (TEAMID)"
             1 valid identities found
        """
        #expect(AppInspector.parseIdentities(output: out) == ["Apple Development: a@b.c (TEAMID)"])
        #expect(AppInspector.parseIdentities(output: "     0 valid identities found\n") == [])
        #expect(AppInspector.parseIdentities(output: "") == [])
    }

    @Test("서명 대상은 중첩 코드 먼저·본체 마지막 (.bundle/.dylib 포함)")
    func signTargetsOrder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AGOSignTest-\(UUID().uuidString).app")
        let plugins = base.appendingPathComponent("Contents/PlugIns")
        let frameworks = base.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let bAppex = plugins.appendingPathComponent("B.appex")
        let aAppex = plugins.appendingPathComponent("A.appex")
        let zBundle = plugins.appendingPathComponent("z.bundle")
        let dDylib = frameworks.appendingPathComponent("d.dylib")
        for url in [aAppex, bAppex, zBundle, dDylib] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        // 전체 경로 정렬: Frameworks/d.dylib < PlugIns/A.appex < PlugIns/B.appex < PlugIns/z.bundle < 본체
        let expected = [
            dDylib.standardizedFileURL,
            aAppex.standardizedFileURL,
            bAppex.standardizedFileURL,
            zBundle.standardizedFileURL,
            base.standardizedFileURL,
        ]
        #expect(AppInspector.signTargets(appURL: base) == expected)
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("AGOPlain-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(AppInspector.signTargets(appURL: plain) == [plain.standardizedFileURL])
    }

    @Test("spctl 게이트: 서명된 변조 앱은 허용, 미서명 변조는 하드차단 아님(로그 키 선택용)")
    func spctlAllowGate() {
        #expect(AppInspector.spctlAllowGate(codesignValid: true, signed: false, tamperEvidence: false))
        #expect(AppInspector.spctlAllowGate(codesignValid: true, signed: true, tamperEvidence: true))
        // 미서명 변조: 하드 차단이 아니라 warnTampered 로그 + blocked 게이트로 간다 (GatePipeline).
        #expect(!AppInspector.spctlAllowGate(codesignValid: false, signed: true, tamperEvidence: true))
        #expect(!AppInspector.spctlAllowGate(codesignValid: true, signed: false, tamperEvidence: true))
        #expect(!AppInspector.spctlAllowGate(codesignValid: false, signed: false, tamperEvidence: true))
    }

    @Test("재귀 xattr 감지 — 루트에 없고 중첩에만 있는 quarantine (RoB.app 사례)")
    func detectsNestedQuarantine() {
        let recursive = """
        /Apps/RoB.app: com.apple.provenance: abcd
        /Apps/RoB.app/Contents/PlugIns/steam_api.bundle/Contents/MacOS/libsteam_api.dylib: com.apple.quarantine: 0083;abc;Safari;x
        """
        #expect(AppInspector.hasQuarantine(xattrOutput: recursive))
        #expect(AppInspector.hasProvenance(xattrOutput: recursive))
        // 비재귀 루트만 보면 quarantine 누락
        let rootOnly = "/Apps/RoB.app: com.apple.provenance: abcd\n"
        #expect(!AppInspector.hasQuarantine(xattrOutput: rootOnly))
        #expect(AppInspector.hasProvenance(xattrOutput: rootOnly))
    }
}

@Suite("타임라인 상태")
struct TimelineTests {
    typealias Step = PipelineTimelineView.Step

    @Test("초기 idle은 전부 대기")
    func idleAllPending() {
        for step in Step.allCases {
            #expect(PipelineTimelineView.state(step: step, phase: .idle, failed: nil) == .pending)
        }
    }

    @Test("진행 중 단계 표시")
    func activeStep() {
        #expect(PipelineTimelineView.state(step: .check, phase: .inspecting, failed: nil) == .active)
        #expect(PipelineTimelineView.state(step: .clean, phase: .cleaning, failed: nil) == .active)
        #expect(PipelineTimelineView.state(step: .check, phase: .cleaning, failed: nil) == .done)
        #expect(PipelineTimelineView.state(step: .run, phase: .cleaning, failed: nil) == .pending)
    }

    @Test("검증 실패 시 앞은 완료·해당은 실패로 남음 (Keep It 사례)")
    func failureLeavesTrace() {
        #expect(PipelineTimelineView.state(step: .check, phase: .idle, failed: .verifying) == .done)
        #expect(PipelineTimelineView.state(step: .clean, phase: .idle, failed: .verifying) == .done)
        #expect(PipelineTimelineView.state(step: .verify, phase: .idle, failed: .verifying) == .failed)
        #expect(PipelineTimelineView.state(step: .run, phase: .idle, failed: .verifying) == .pending)
    }

    @Test("준비·차단은 전부 완료")
    func terminalAllDone() {
        for step in Step.allCases {
            #expect(PipelineTimelineView.state(step: step, phase: .ready, failed: nil) == .done)
            #expect(PipelineTimelineView.state(step: step, phase: .blocked, failed: nil) == .done)
        }
    }

    @Test("서명 단계 매핑 (5단계)")
    func signingStep() {
        #expect(Step.allCases.count == 5)
        #expect(PipelineTimelineView.stepIndex(phase: .signing) == 3)
        #expect(PipelineTimelineView.state(step: .sign, phase: .signing, failed: nil) == .active)
        #expect(PipelineTimelineView.state(step: .verify, phase: .signing, failed: nil) == .done)
        #expect(PipelineTimelineView.state(step: .run, phase: .signing, failed: nil) == .pending)
        #expect(PipelineTimelineView.state(step: .sign, phase: .idle, failed: .signing) == .failed)
    }
}
@Suite("상태머신·에러코드")
struct PipelineModelTests {
    @Test("경고 제목 판정 — 로케일 무관 구조 (개발서명 사례)")
    func warningTitles() {
        var devSigned = PipelineVerdict()
        devSigned.codesignValid = true
        devSigned.spctlNote = "/tmp/B.app: rejected"
        #expect(!VerdictCardView.warningTitle(verdict: devSigned).isEmpty)

        let tampered = PipelineVerdict(modifiedFiles: ["a", "b"], codesignNote: "", spctlNote: "", codesignValid: false)
        #expect(VerdictCardView.warningTitle(verdict: tampered).contains("2"))

        #expect(!VerdictCardView.warningTitle(verdict: .empty).isEmpty)
    }

    @Test("한/영 문자열 테이블 키 일치")
    func stringsTablesMatch() {
        let bundle = Bundle(for: PipelineViewModel.self)
        guard
            let koPath = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "ko"),
            let enPath = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"),
            let ko = NSDictionary(contentsOfFile: koPath) as? [String: String],
            let en = NSDictionary(contentsOfFile: enPath) as? [String: String]
        else {
            Issue.record("Localizable.strings 리소스 없음 (테스트 타깃 resources 확인)")
            return
        }
        #expect(Set(ko.keys) == Set(en.keys))
        #expect(ko.count > 50)
        #expect(ko["help.title"] == "열어줘 도움말")
        #expect(en["help.title"] == "AGO Help")
        #expect(ko["step.check"] == "확인")
        #expect(en["step.check"] == "Check")
    }
    @Test("종료 카운트다운 5→1 (마지막 틱은 실제 종료되므로 호출 금지)")
    func quitCountdown() async {
        let model = await PipelineViewModel()
        await model.startQuitCountdown()
        let first = await MainActor.run { model.quitCountdown }
        #expect(first == 5)
        for _ in 0..<4 {
            await model.tickQuitCountdown()
        }
        let last = await MainActor.run { model.quitCountdown }
        #expect(last == 1)
        await model.reset()
    }
    @Test("판정 기본값은 빈 상태")
    func emptyVerdict() {
        #expect(PipelineVerdict.empty.modifiedFiles.isEmpty)
        #expect(!PipelineVerdict.empty.hadProvenance)
        #expect(PipelineVerdict.empty == PipelineVerdict())
    }

    @Test("로그 줄 종류별 표시 접두")
    func logLineKinds() {
        let cmd = LogLine(kind: .command, text: "$ ls")
        let ok = LogLine(kind: .success, text: "통과")
        let ng = LogLine(kind: .failure, text: "실패")
        #expect(cmd.kind == .command)
        #expect(ok.kind == .success)
        #expect(ng.kind == .failure)
    }

    @Test("에러코드가 한글 메시지를 가진다")
    func errorCodesHaveKoreanMessages() {
        // 시스템 locale 무관: 앱 번들의 ko 테이블에서 직접 읽는다.
        // errorDescription은 NSLocalizedString라 영어 locale CI 러너에선 영문이 나온다.
        let ko = Self.koreanStrings()
        #expect(ko["err.signing"]?.contains("서명") == true)
        #expect(ko["err.notapp"]?.contains(".app") == true)
        #expect(ko["err.gatekeeper"]?.contains("거부") == true)
        #expect(AppError.notAnAppBundle("x").code == "E-MAC-VAL-2002")
        #expect(AppError.quarantineRemoveFailed("x").code == "E-MAC-PERM-2002")
        #expect(AppError.signatureInvalid([]).code == "E-MAC-VAL-2001")
        #expect(AppError.gatekeeperRejected("x").code == "E-MAC-PERM-2003")
        #expect(AppError.launchFailed("x").code == "E-MAC-PERM-2004")
        #expect(AppError.signingFailed("x").code == "E-MAC-PERM-2005")
    }

    /// 앱 번들(테스트 호스트)의 ko.lproj 테이블을 시스템 locale과 무관하게 읽는다.
    private static func koreanStrings() -> [String: String] {
        guard let url = Bundle(for: GatePipeline.self)
            .url(forResource: "Localizable", withExtension: "strings", subdirectory: "ko.lproj"),
            let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            return [:]
        }
        return dict
    }
}
