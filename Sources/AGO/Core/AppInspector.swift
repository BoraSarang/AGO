import Foundation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// AppInspector — .app/.dmg/.pkg 형식 검사 + xattr/codesign/spctl/pkgutil 결과 파싱
// 순수 함수 위주라 단위 테스트가 쉽다. 실제 명령 실행은 GatePipeline 담당.

/// 드롭 가능한 번들 종류.
enum DropKind: String, Equatable, Sendable {
    case app
    case dmg
    case pkg
}

/// `codesign --verify` 결과.
enum CodesignResult: Equatable, Sendable {
    /// 서명 정상 (`valid on disk`).
    case valid
    /// 변조 의심 (`file added:` / `file modified:` 행 존재). 연관값 = 의심 파일 목록.
    case tampered([String])
    /// 그 외 검증 실패 (미서명 등). 연관값 = 원문 요약.
    case broken(String)
}

/// `spctl -a` 평가 결과.
enum SpctlResult: Equatable, Sendable {
    case accepted
    case rejected(String)
}

/// `pkgutil --check-signature` 결과.
enum PkgSignatureResult: Equatable, Sendable {
    /// Developer ID 등 유효 서명. 연관값 = 요약(인증서 이름 등).
    case signed(String)
    /// 서명 없음.
    case unsigned
    /// 서명 무효/깨짐. 연관값 = 원문 요약.
    case invalid(String)
}

enum AppInspector {
    // MARK: - 형식 검사 (app / dmg / pkg)

    /// 지원 확장자 → DropKind. 미지원이면 nil.
    static func dropKind(url: URL) -> DropKind? {
        switch url.pathExtension.lowercased() {
        case "app": return .app
        case "dmg": return .dmg
        case "pkg": return .pkg
        default: return nil
        }
    }

    /// 드롭/선택 경로 형식 검사.
    /// - `.app`: 번들 구조(`Contents/Info.plist`)
    /// - `.dmg`/`.pkg`: 파일 존재만 확인 (내부 구조는 마운트·설치 단계에서)
    static func validateDrop(url: URL) throws {
        guard let kind = dropKind(url: url) else {
            throw AppError.unsupportedFormat(url.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.unsupportedFormat(url.lastPathComponent)
        }
        if kind == .app {
            let infoPlist = url.appendingPathComponent("Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: infoPlist.path) else {
                throw AppError.unsupportedFormat(url.lastPathComponent)
            }
        }
        DebugLogger.info(feature: "GATEOPEN", L10n.f("pipe.formatOK", url.lastPathComponent))
    }

    /// `.app` 전용 검사 (기존 호출부 호환).
    static func validateAppBundle(url: URL) throws {
        guard url.pathExtension.lowercased() == "app" else {
            throw AppError.unsupportedFormat(url.lastPathComponent)
        }
        try validateDrop(url: url)
    }

    // MARK: - xattr 파싱

    /// `xattr -l` 출력에 quarantine 속성이 있는지 확인.
    static func hasQuarantine(xattrOutput: String) -> Bool {
        xattrOutput.contains("com.apple.quarantine")
    }

    /// `xattr -l` 출력에 출처 속성(`com.apple.provenance`)이 있는지 확인.
    /// macOS 15 이후 인터넷 다운로드 파일에 함께 붙는 스탬프다. quarantine만 지우고
    /// 이게 남으면 macOS 26+는 실행 시점 재평가(Gatekeeper 확인 창)를 다시 띄우므로
    /// quarantine과 함께 처리해야 한다.
    static func hasProvenance(xattrOutput: String) -> Bool {
        xattrOutput.contains("com.apple.provenance")
    }

    /// `xattr -l` 출력에 권한 귀속 속성(`com.apple.macl`)이 있는지 확인.
    /// 드래그·"다음으로 열기"로 다른 앱이 실행할 때 macOS가 붙이는 스탬프다. 남아 있으면
    /// 크랙/미인정 서명 앱의 경우 TCC(개발자 도구 등) 요청 시점에 커널 정책이 강제종료하므로
    /// 실행 정리는 quarantine/provenance와 함께 처리한다.
    static func hasMacl(xattrOutput: String) -> Bool {
        xattrOutput.contains("com.apple.macl")
    }

    // MARK: - codesign 파싱 (PLAN 2.2 단계 4)

    /// `codesign --verify --deep --strict --verbose=4` 출력 파싱.
    static func parseCodesign(output: String, exitCode: Int32) -> CodesignResult {
        let suspectFiles = output
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let range = trimmed.range(of: "file added: ") {
                    return String(trimmed[range.upperBound...])
                }
                if let range = trimmed.range(of: "file modified: ") {
                    return String(trimmed[range.upperBound...])
                }
                return nil
            }
        if !suspectFiles.isEmpty {
            return .tampered(suspectFiles)
        }
        if exitCode == 0, output.contains("valid on disk") {
            return .valid
        }
        let summary = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? "알 수 없는 검증 실패"
        return .broken(summary)
    }

    // MARK: - codesign 표시용 요약 (잡음 제거)

    /// `--verbose=4` 출력에서 `--prepared:`/`--validated:` 행을 걷어내고 신호만 남긴다.
    /// 생략된 행이 있으면 말미에 요약 1줄을 덧붙인다. 파싱에는 쓰지 않는다.
    static func summarizeCodesign(output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        let signal = lines.filter { line in
            !line.contains("--prepared:") && !line.contains("--validated:")
        }
        let dropped = lines.count - signal.count
        var result = signal.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if dropped > 0 {
            if !result.isEmpty { result += "\n" }
            result += "… \(dropped)개 구성요소 검증됨 (상세 생략)"
        }
        return result
    }

    // MARK: - 서명 신원 파싱 (T-AGO-22)

    /// `security find-identity -v -p codesigning` 출력을 실행한다 (빈 문자열이면 실패).
    static func findIdentityOutput() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        // 출력을 먼저 소진 후 wait (pipe 데드락 방지 — GatePipeline.runProcess와 동일).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// find-identity 출력에서 서명 신원 이름 목록을 추출한다.
    /// 예: `  1) 76811B50... "Apple Development: a@b.c (TEAMID)"` → `Apple Development: a@b.c (TEAMID)`.
    /// 행은 `1) <SHA1> "<이름>"` 형식이라, 순번 확인 후 마지막 큰따옴표쌍 안만 뽑는다.
    /// `N valid identities found` 집계 행은 제외한다.
    static func parseIdentities(output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let paren = trimmed.range(of: ") ") else { return nil }
                let head = trimmed[..<paren.lowerBound]
                // `1)` 같은 순번인지 확인 (집계 행 `1 valid identities found` 제외).
                guard !head.isEmpty, head.allSatisfy({ $0.isNumber }) else { return nil }
                let rest = String(trimmed[paren.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard let firstQuote = rest.firstIndex(of: "\""),
                      let lastQuote = rest.lastIndex(of: "\""),
                      firstQuote < lastQuote else { return nil }
                let start = rest.index(after: firstQuote)
                return String(rest[start..<lastQuote])
            }
    }

    // MARK: - 서명 대상 순서 (T-AGO-21)

    /// 서명할 대상을 순서대로 반환한다.
    /// - PlugIns 안의 `*.appex`·`*.bundle`, Frameworks 안의 `*.framework`·`*.dylib`을 먼저 개별 서명
    /// - `.app` 본체는 마지막 (중첩 코드가 모두 유효해진 뒤 서명)
    /// `--deep` 대신 개별 서명용. 대상이 없으면 본체만 반환한다.
    /// 실제 파일 존재를 확인해 표시 경로가 일관되게 한다 (`/private` 리졸브 정규화).
    static func signTargets(appURL: URL) -> [URL] {
        let root = appURL.standardizedFileURL
        var targets: [URL] = []
        let pluginDir = root.appendingPathComponent("Contents/PlugIns")
        let nestedExts: [String] = ["appex", "bundle"]
        if let items = try? FileManager.default.contentsOfDirectory(
            at: pluginDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            targets.append(contentsOf: items.filter { nestedExts.contains($0.pathExtension) })
        }
        let frameworkDir = root.appendingPathComponent("Contents/Frameworks")
        let codeExts: [String] = ["framework", "dylib"]
        if let items = try? FileManager.default.contentsOfDirectory(
            at: frameworkDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            targets.append(contentsOf: items.filter { codeExts.contains($0.pathExtension) })
        }
        targets = targets.map { $0.standardizedFileURL }
            .sorted { $0.path < $1.path }
        targets.append(root)
        DebugLogger.info(feature: "GATEOPEN", "서명 대상 \(targets.count)개 (중첩 코드 우선)")
        return targets
    }

    /// spctl 거부 시 "경고 후 허용"(blocked+체크박스) 게이트 판정.
    /// - 서명이 현재 유효(`codesignValid`)할 때만 실행 게이트를 열 수 있다.
    /// - 변조 증거가 있으면 반드시 우리가 서명한 경우(`signed`)에만 연다 (증거는 그대로 남음).
    static func spctlAllowGate(codesignValid: Bool, signed: Bool, tamperEvidence: Bool) -> Bool {
        codesignValid && (signed || !tamperEvidence)
    }

    // MARK: - pkgutil 서명 파싱

    /// `pkgutil --check-signature` 출력 파싱.
    static func parsePkgSignature(output: String, exitCode: Int32) -> PkgSignatureResult {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let lower = lines.map { $0.lowercased() }
        if lower.contains(where: { $0.contains("no signature") || $0.contains("not signed") }) {
            return .unsigned
        }
        if lower.contains(where: { $0.contains("status: signed") || $0.contains("developer id installer") || $0.contains("certificate") && $0.contains("signed") }) {
            // 인증서 체인에서 첫 번째 발급자 라인을 요약으로 사용 (`1. ` 순번 제거).
            let cert = lines.first { $0.contains("Developer ID") || $0.contains("Apple Development") || $0.contains("PackageKit") }
                ?? lines.first { $0.contains("Status:") } ?? "signed"
            let stripped = cert.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
            return .signed(stripped.isEmpty ? cert : stripped)
        }
        if exitCode != 0 {
            let summary = lines.last ?? "signature check failed"
            if summary.lowercased().contains("status: signed") {
                return .signed(summary)
            }
            return .invalid(summary)
        }
        let summary = lines.first { $0.lowercased().contains("status") } ?? (lines.last ?? "signed")
        if summary.lowercased().contains("signed") && !summary.lowercased().contains("not signed") {
            return .signed(summary)
        }
        return .invalid(summary)
    }

    // MARK: - spctl 파싱 (PLAN 2.2 단계 5)

    /// `spctl -a` 출력 파싱. `context`는 `open`(기본) 또는 `install`(pkg).
    static func parseSpctl(output: String, exitCode: Int32) -> SpctlResult {
        if exitCode == 0, output.contains("accepted") {
            return .accepted
        }
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let summary = lines.first(where: { $0.contains("rejected") })
            ?? lines.last
            ?? "Gatekeeper 평가 실패"
        return .rejected(summary)
    }
}
