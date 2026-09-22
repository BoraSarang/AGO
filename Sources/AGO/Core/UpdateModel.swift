import Foundation
import Observation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// UpdateModel — 업데이트 확인 상태 + 주기 + 마지막 확인 시각 영속화 (가이드 구조)
// 함정 주의: updateCheckedAt은 UserDefaults에 저장한다 (메모리만으론 주기 설정이 무의미).

@MainActor @Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case unavailable(UpdateError)
    }

    enum Frequency: String, CaseIterable, Identifiable, Sendable {
        case atLaunch, daily, weekly, never

        var id: String { rawValue }

        var label: String {
            switch self {
            case .atLaunch: return L10n.s("update.freqLaunch")
            case .daily: return L10n.s("update.freqDaily")
            case .weekly: return L10n.s("update.freqWeekly")
            case .never: return L10n.s("update.freqNever")
            }
        }
    }

    static let defaultFrequency: Frequency = .weekly
    private static let kFrequency = "settings.updateFrequency"
    private static let kCheckedAt = "settings.updateLastChecked"

    var state: State = .idle
    /// 업데이트 시트 표시 ( ContentView의 .sheet 바인딩 ).
    var showingSheet = false
    var frequency: Frequency {
        didSet { UserDefaults.standard.set(frequency.rawValue, forKey: Self.kFrequency) }
    }
    /// 마지막 확인 시각 — UserDefaults 영속화 (가이드 실패 5번 방지).
    private(set) var checkedAt: Date?

    /// 이번 실행 시점. `.atLaunch`는 "지난 실행에서 확인했는지" 판정 기준.
    private let launchDate = Date()

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.kFrequency) ?? Self.defaultFrequency.rawValue
        frequency = Frequency(rawValue: raw) ?? Self.defaultFrequency
        if let stored = UserDefaults.standard.object(forKey: Self.kCheckedAt) as? Double {
            checkedAt = Date(timeIntervalSince1970: stored)
        }
    }

    /// 사용 가능한 릴리스 (있을 때만).
    var availableRelease: GitHubRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    /// 주기 판정 순수 함수 (테스트 대상). checkedAt이 nil이면 항상 충족.
    nonisolated static func isDue(
        frequency: Frequency,
        checkedAt: Date?,
        now: Date = Date(),
        launchDate: Date
    ) -> Bool {
        switch frequency {
        case .never:
            return false
        case .atLaunch:
            return checkedAt.map { $0 < launchDate } ?? true
        case .daily:
            return checkedAt.map { now.timeIntervalSince($0) >= 86_400 } ?? true
        case .weekly:
            return checkedAt.map { now.timeIntervalSince($0) >= 604_800 } ?? true
        }
    }

    /// 앱 실행 시·주기가 됐을 때만 조용히 확인한다.
    func maybeAutoCheck() async {
        guard frequency != .never else { return }
        if case .checking = state { return }
        guard Self.isDue(frequency: frequency, checkedAt: checkedAt, launchDate: launchDate) else { return }
        await checkNow()
    }

    /// 수동 확인 (도움말 시트). 새 버전이면 시트를 띄운다 (`openSheet: false`면 호출부가 제어).
    func checkNow(openSheet: Bool = true) async {
        guard !isChecking else { return }
        state = .checking
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        DebugLogger.info(feature: "업데이트", "확인 시작 (현재 \(current), 주기 \(frequency.rawValue))")
        do {
            let release = try await ReleaseChecker.fetchLatest(currentVersion: current)
            persistCheckedAt()
            if ReleaseChecker.isNewer(tag: release.tagName, than: current) {
                state = .available(release)
                if openSheet { showingSheet = true }
                DebugLogger.info(feature: "업데이트", "새 버전 사용 가능: \(release.tagName)")
            } else {
                state = .upToDate
                DebugLogger.info(feature: "업데이트", "최신 버전 (\(release.tagName))")
            }
        } catch let error as UpdateError {
            // 실패는 checkedAt을 저장하지 않는다 — 다음 실행·수동 확인에서 재시도.
            state = .unavailable(error)
            DebugLogger.info(feature: "업데이트", error == .noPublishedRelease
                ? "게시된 릴리스 없음 (404)"
                : "조회 실패")
        } catch {
            state = .unavailable(.fetchFailed)
            DebugLogger.info(feature: "업데이트", "조회 실패 (알 수 없음)")
        }
    }

    /// 상태 메시지 (도움말 시트 행 표시용).
    var statusMessage: String? {
        switch state {
        case .idle:
            return nil
        case .checking:
            return L10n.s("update.checking")
        case .upToDate:
            return L10n.s("update.upToDate")
        case .available(let release):
            return L10n.f("update.badge", release.tagName)
        case .unavailable(let error):
            switch error {
            case .noPublishedRelease: return L10n.s("update.noRelease")
            case .fetchFailed: return L10n.s("update.fetchFailed")
            }
        }
    }

    private func persistCheckedAt() {
        let now = Date()
        checkedAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.kCheckedAt)
    }
}
