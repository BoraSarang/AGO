import Foundation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// L10n — UI 문자열 현지화 헬퍼 (T-AGO-20, 앱 내 한/영 지원)
// Bundle(for:) 기준이라 앱 번들·테스트 번들 양쪽에서 Localizable.strings를 찾는다.

enum L10n {
    static var bundle: Bundle { Bundle(for: GatePipeline.self) }

    static func s(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: s(key), arguments: args)
    }
}
