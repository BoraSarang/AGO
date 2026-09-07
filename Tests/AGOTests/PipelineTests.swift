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
        #expect(AppError.notAnAppBundle("x").errorDescription?.contains(".app") == true)
        #expect(AppError.quarantineRemoveFailed("x").code == "E-MAC-PERM-2002")
        #expect(AppError.signatureInvalid([]).code == "E-MAC-VAL-2001")
        #expect(AppError.gatekeeperRejected("x").code == "E-MAC-PERM-2003")
        #expect(AppError.launchFailed("x").code == "E-MAC-PERM-2004")
    }
}
