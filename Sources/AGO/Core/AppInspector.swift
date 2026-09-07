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
