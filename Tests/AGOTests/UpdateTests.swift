import Foundation
import Testing
@testable import AGO

// 업데이트 확인 단위 테스트 — 버전 비교·JSON 파싱·주기 판정 (macos-app-update 가이드)

@Suite("버전 비교")
struct VersionCompareTests {
    @Test("태그가 더 크면 업데이트 있음")
    func newerTag() {
        #expect(ReleaseChecker.isNewer(tag: "v0.3.0", than: "0.2.2"))
        #expect(ReleaseChecker.isNewer(tag: "v0.2.3", than: "0.2.2"))
        #expect(ReleaseChecker.isNewer(tag: "0.10.0", than: "0.9.9")) // 숫자 비교 (문자열 "10"<"9" 아님)
        #expect(ReleaseChecker.isNewer(tag: "v1.0.0", than: "0.9.9"))
    }

    @Test("같거나 작으면 업데이트 없음")
    func notNewer() {
        #expect(!ReleaseChecker.isNewer(tag: "v0.2.2", than: "0.2.2"))
        #expect(!ReleaseChecker.isNewer(tag: "v0.2.1", than: "0.2.2"))
        #expect(!ReleaseChecker.isNewer(tag: "v0.2.2", than: "0.2.10"))
        #expect(!ReleaseChecker.isNewer(tag: "v0.1.9", than: "0.2.0"))
    }

    @Test("누락 성분은 0으로 간주 (v0.2 == 0.2.0)")
    func missingComponents() {
        #expect(!ReleaseChecker.isNewer(tag: "v0.2", than: "0.2.0"))
        #expect(ReleaseChecker.isNewer(tag: "v0.2.1", than: "0.2"))
        #expect(ReleaseChecker.normalize("v0.2.2") == "0.2.2")
        #expect(ReleaseChecker.normalize("0.2.2") == "0.2.2")
    }

    @Test("compareVersions 3-way 판정")
    func compareResult() {
        #expect(ReleaseChecker.compareVersions("0.2.2", "0.2.2") == .orderedSame)
        #expect(ReleaseChecker.compareVersions("0.2.1", "0.2.2") == .orderedAscending)
        #expect(ReleaseChecker.compareVersions("0.3.0", "0.2.2") == .orderedDescending)
    }
}

@Suite("릴리스 JSON 파싱")
struct ReleaseDecodeTests {
    @Test("tag_name/html_url/body 디코딩")
    func decodesFull() throws {
        let json = """
        {"tag_name":"v0.2.2","html_url":"https://github.com/BoraSarang/AGO/releases/tag/v0.2.2",
         "name":"v0.2.2 — 릴리스","body":"## 변경\\n- 실행 위임 개선"}
        """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v0.2.2")
        #expect(release.htmlURL.contains("v0.2.2"))
        #expect(release.body?.contains("실행 위임") == true)
    }

    @Test("name·body 없는 응답도 디코딩 (옵셔널)")
    func decodesMinimal() throws {
        let json = #"{"tag_name":"v0.1.0","html_url":"https://example.com/r"}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v0.1.0")
        #expect(release.name == nil)
        #expect(release.body == nil)
    }

    @Test("깨진 JSON은 fetchFailed로 매핑할 수 있는 디코드 실패")
    func decodeFailureThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GitHubRelease.self, from: Data("not json".utf8))
        }
    }
}

@Suite("업데이트 주기 판정")
struct UpdateDueTests {
    private let launch = Date()
    private let now = Date()

    @Test("never은 항상 미충족")
    func neverNotDue() {
        #expect(!UpdateModel.isDue(frequency: .never, checkedAt: nil, now: now, launchDate: launch))
        #expect(!UpdateModel.isDue(
            frequency: .never,
            checkedAt: now.addingTimeInterval(-999_999),
            now: now,
            launchDate: launch))
    }

    @Test("미확인이면(frequency) 항상 충족")
    func nilCheckedAtIsDue() {
        #expect(UpdateModel.isDue(frequency: .daily, checkedAt: nil, now: now, launchDate: launch))
        #expect(UpdateModel.isDue(frequency: .weekly, checkedAt: nil, now: now, launchDate: launch))
        #expect(UpdateModel.isDue(frequency: .atLaunch, checkedAt: nil, now: now, launchDate: launch))
    }

    @Test("daily — 24시간 전 확인했으면 충족, 방금 확인했으면 미충족")
    func dailyDue() {
        let old = now.addingTimeInterval(-86_400)
        let fresh = now.addingTimeInterval(-3_600)
        #expect(UpdateModel.isDue(frequency: .daily, checkedAt: old, now: now, launchDate: launch))
        #expect(!UpdateModel.isDue(frequency: .daily, checkedAt: fresh, now: now, launchDate: launch))
    }

    @Test("weekly — 7일 전 확인했으면 충족")
    func weeklyDue() {
        let old = now.addingTimeInterval(-604_800)
        let fresh = now.addingTimeInterval(-86_400)
        #expect(UpdateModel.isDue(frequency: .weekly, checkedAt: old, now: now, launchDate: launch))
        #expect(!UpdateModel.isDue(frequency: .weekly, checkedAt: fresh, now: now, launchDate: launch))
    }

    @Test("atLaunch — 지난 실행에서 확인했으면 충족, 이번 실행에 확인했으면 미충족")
    func atLaunchDue() {
        let previousLaunch = launch.addingTimeInterval(-3_600) // 이번 실행 1시간 전
        let thisSession = launch.addingTimeInterval(10)         // 이번 실행 중 확인
        #expect(UpdateModel.isDue(
            frequency: .atLaunch, checkedAt: previousLaunch, now: now, launchDate: launch))
        #expect(!UpdateModel.isDue(
            frequency: .atLaunch, checkedAt: thisSession, now: now, launchDate: launch))
    }
}
