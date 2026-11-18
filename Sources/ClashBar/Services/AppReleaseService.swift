import Foundation

enum AppReleaseServiceError: Error {
    case invalidResponse
    case statusCode(Int)
}

enum AppReleaseService {
    /// This fork, not upstream: a patched build must never be told to "update" to a release
    /// that does not contain the fixes it is running.
    static let repositorySlug = "cczhao12/ClashBar"

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/\(repositorySlug)/releases/latest")!

    static func fetchLatestRelease(currentVersion: String) async throws -> AppReleaseInfo {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClashBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let session = Self.makeSession()
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppReleaseServiceError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw AppReleaseServiceError.statusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(AppReleaseInfo.self, from: data)
    }

    private static func makeSession() -> URLSession {
        URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 8,
            timeoutIntervalForResource: 15))
    }
}
