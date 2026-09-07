import Foundation
import os

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// 최소 DebugLogger — 다음 세션에서 DebugPanel 연동 시 확장 (T-AGO-05)

enum DebugLogger {
    private static let log = Logger(subsystem: "com.borasarang.ago", category: "app")

    static func info(feature: String, _ message: String) {
        log.info("[INFO] [\(feature)] \(message)")
    }

    static func perf(_ message: String) {
        log.info("[PERF] \(message)")
    }

    static func error(code: String, _ message: String) {
        log.error("[ERROR] \(code) \(message)")
    }
}
