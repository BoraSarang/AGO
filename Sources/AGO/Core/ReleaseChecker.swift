import Foundation

// [SYSTEM LANGUAGE LOCK] 응답과 추론은 모두 한국어
// ReleaseChecker — GitHub Releases 최신 버전 조회 + 버전 비교 (macos-app-update 가이드 적용)
// 인앱 자동 설치는 하지 않는다: 확인만 하고 릴리스 페이지로 연결 (공증 없이 교체 금지).

struct GitHubRelease: Codable, Sendable, Equatable {
    let tagName: String
    let htmlURL: String
    let name: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case body
    }
}

/// 업데이트 확인 실패 원인 (404를 분리해 "릴리스 없음"과 네트워크 오류를 구분).
enum UpdateError: Error, Equatable {
    case noPublishedRelease
    case fetchFailed
}

enum ReleaseChecker {
    static let repository = "BoraSarang/AGO"

    /// `releases/latest` 조회. 릴리스 0개면 API가 404라 `.noPublishedRelease`로 구분.
    /// User-Agent는 하드코딩하지 않고 번들 버전을 받는다 (가이드 실패 6번 방지).
    static func fetchLatest(currentVersion: String) async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.fetchFailed
        }
        var request = URLRequest(url: url)
        request.setValue("AGO/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.fetchFailed }
        if http.statusCode == 404 { throw UpdateError.noPublishedRelease }
        guard (200...299).contains(http.statusCode) else { throw UpdateError.fetchFailed }
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.fetchFailed
        }
    }

    /// 태그(v0.2.3)가 현재 버전(0.2.2)보다 크면 true. 문자열 비교가 아니라 숫자 비교.
    static func isNewer(tag: String, than current: String) -> Bool {
        compareVersions(normalize(tag), normalize(current)) == .orderedDescending
    }

    /// "v" 접두만 제거한다.
    static func normalize(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    /// 점 구분 숫자 버전 비교. 성분이 없으면 0으로 간주 (v0.2 == 0.2.0).
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
