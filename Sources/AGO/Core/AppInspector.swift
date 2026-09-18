import Foundation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// AppInspector — .app 형식 검사 + xattr/codesign/spctl 결과 파싱 (T-AGO-11)
// 순수 함수 위주라 단위 테스트가 쉽다. 실제 명령 실행은 GatePipeline 담당.

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

enum AppInspector {
    // MARK: - 형식 검사 (PLAN 2.2 단계 1)

    /// `.app` 확장자 + 번들 구조(`Contents/Info.plist`) 확인.
    /// - Throws: `AppError.notAnAppBundle`
    static func validateAppBundle(url: URL) throws {
        guard url.pathExtension == "app" else {
            throw AppError.notAnAppBundle(url.lastPathComponent)
        }
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlist.path) else {
            throw AppError.notAnAppBundle(url.lastPathComponent)
        }
        DebugLogger.info(feature: "GATEOPEN", L10n.f("pipe.formatOK", url.lastPathComponent))
    }

    // MARK: - xattr 파싱 (PLAN 2.2 단계 2)

    /// `xattr -l` 출력에 quarantine 속성이 있는지 확인.
    static func hasQuarantine(xattrOutput: String) -> Bool {
        xattrOutput.contains("com.apple.quarantine")
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
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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

    // MARK: - spctl 파싱 (PLAN 2.2 단계 5)

    /// `spctl -a -vv` 출력 파싱.
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
