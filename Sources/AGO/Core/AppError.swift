import Foundation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// 에러코드 체계 — 다음 세션에서 파이프라인 구현 시 사용 (T-AGO-02 이후)
// 형식: E-MAC-{CATEGORY}-{NUM4} (공통 가이드 4장 준수)

enum AppError: LocalizedError {
    case quarantineInspectFailed(String)
    case quarantineRemoveFailed(String)
    case signatureInvalid([String])
    case gatekeeperRejected(String)
    case launchFailed(String)
    case notAnAppBundle(String)
    case unsupportedFormat(String)
    case signingFailed(String)
    case dmgMountFailed(String)

    var code: String {
        switch self {
        case .quarantineInspectFailed: return "E-MAC-PERM-2001"
        case .quarantineRemoveFailed: return "E-MAC-PERM-2002"
        case .signatureInvalid: return "E-MAC-VAL-2001"
        case .gatekeeperRejected: return "E-MAC-PERM-2003"
        case .launchFailed: return "E-MAC-PERM-2004"
        case .notAnAppBundle, .unsupportedFormat: return "E-MAC-VAL-2002"
        case .signingFailed: return "E-MAC-PERM-2005"
        case .dmgMountFailed: return "E-MAC-PERM-2006"
        }
    }

    var errorDescription: String? {
        switch self {
        case .quarantineInspectFailed: return L10n.s("err.inspect")
        case .quarantineRemoveFailed: return L10n.s("err.remove")
        case .signatureInvalid: return L10n.s("err.sign")
        case .gatekeeperRejected(let d): return L10n.f("err.gatekeeper", d)
        case .launchFailed(let d): return L10n.f("err.launch", d)
        case .notAnAppBundle(let d), .unsupportedFormat(let d): return L10n.f("err.notapp", d)
        case .signingFailed(let d): return L10n.f("err.signing", d)
        case .dmgMountFailed(let d): return L10n.f("err.dmg", d)
        }
    }
}
