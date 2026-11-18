import Foundation

struct WorkingDirectoryManager {
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    var rootDirectoryURL: URL {
        self.homeDirectory.appendingPathComponent("Library/Application Support/clashbar", isDirectory: true)
    }

    var configDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("config", isDirectory: true)
    }

    var logsDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("logs", isDirectory: true)
    }

    var stateDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("state", isDirectory: true)
    }

    var iconDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("icon", isDirectory: true)
    }

    var coreDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("core", isDirectory: true)
    }

    var managedMihomoBinaryURL: URL {
        self.coreDirectoryURL.appendingPathComponent("mihomo", isDirectory: false)
    }

    func bootstrapDirectories(fileManager: FileManager = .default) throws {
        try self.createDirectoryIfNeeded(self.rootDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.configDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.logsDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.stateDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.iconDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.coreDirectoryURL, fileManager: fileManager)
    }

    func normalizeAndValidateWithinRoot(_ url: URL, mustBeDirectory: Bool? = nil) throws -> URL {
        let standardized = url.standardizedFileURL
        let root = self.rootDirectoryURL.standardizedFileURL
        guard self.isDescendantOrEqual(standardized, parent: root) else {
            throw NSError(
                domain: "ClashBar.PathSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Path escapes ClashBar working directory: \(standardized.path)"])
        }

        if let mustBeDirectory {
            let resolved = standardized.resolvingSymlinksInPath()
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory != mustBeDirectory {
                throw NSError(
                    domain: "ClashBar.PathSecurity",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: mustBeDirectory
                        ? "Expected directory path: \(standardized.path)"
                        : "Expected file path: \(standardized.path)"])
            }
        }

        return standardized
    }

    private func createDirectoryIfNeeded(_ url: URL, fileManager: FileManager) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw NSError(
                    domain: "ClashBar.PathSecurity",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Expected directory but found file: \(url.path)"])
            }
            return
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func isDescendantOrEqual(_ child: URL, parent: URL) -> Bool {
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents

        guard parentComponents.count <= childComponents.count else { return false }
        return zip(parentComponents, childComponents).allSatisfy { $0 == $1 }
    }
}

@MainActor
final class ConfigDirectoryManager {
    private let workingDirectoryManager: WorkingDirectoryManager

    private(set) var configDirectory: URL?
    private(set) var availableConfigs: [URL] = []
    private(set) var selectedConfig: URL?

    init(workingDirectoryManager: WorkingDirectoryManager = WorkingDirectoryManager()) {
        self.workingDirectoryManager = workingDirectoryManager
    }

    func chooseConfigDirectory() -> URL? {
        do {
            try self.workingDirectoryManager.bootstrapDirectories()
            let target = try workingDirectoryManager.normalizeAndValidateWithinRoot(
                self.workingDirectoryManager.configDirectoryURL,
                mustBeDirectory: true)
            self.configDirectory = target
            self.reloadConfigs()
            return target
        } catch {
            return nil
        }
    }

    func setConfigDirectory(_ url: URL) {
        guard let safeURL = try? workingDirectoryManager.normalizeAndValidateWithinRoot(url, mustBeDirectory: true),
              safeURL == workingDirectoryManager.configDirectoryURL.standardizedFileURL
        else {
            return
        }
        self.configDirectory = safeURL
        self.reloadConfigs()
    }

    func selectConfig(_ url: URL) {
        guard let configDirectory else { return }
        let safeConfig = try? self.workingDirectoryManager.normalizeAndValidateWithinRoot(url, mustBeDirectory: false)
        guard let safeConfig,
              safeConfig.deletingLastPathComponent() == configDirectory,
              ["yaml", "yml"].contains(safeConfig.pathExtension.lowercased())
        else {
            return
        }
        self.selectedConfig = safeConfig
    }

    @discardableResult
    func reloadConfigs() -> [URL] {
        guard let configDirectory else {
            self.applyScannedConfigs([])
            return []
        }

        let files = Self.scanConfigFiles(in: configDirectory)
        self.applyScannedConfigs(files)
        return files
    }

    func applyScannedConfigs(_ files: [URL]) {
        self.availableConfigs = files
        if let selectedConfig, files.contains(selectedConfig) {
            return
        }
        self.selectedConfig = files.first
    }

    nonisolated static func scanConfigFiles(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        return children.filter { fileURL in
            let resolved = fileURL.resolvingSymlinksInPath()
            let isRegularFile = (try? resolved.resourceValues(forKeys: keys).isRegularFile) ?? false
            let fileExtension = fileURL.pathExtension.lowercased()
            return isRegularFile && (fileExtension == "yaml" || fileExtension == "yml")
        }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

struct ConfigImportService {
    private let maxRemoteConfigBytes = 5 * 1024 * 1024

    @discardableResult
    func writeConfigData(_ data: Data, to targetURL: URL) throws -> Bool {
        guard !data.isEmpty else {
            throw NSError(
                domain: "ClashBar.ConfigImport",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Remote config response is empty"])
        }

        guard self.validateClashConfigData(data) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary data>"
            let message = """
            Remote config is not a valid Clash configuration (missing proxy keys). \
            Content preview: \(preview)
            """
            throw NSError(
                domain: "ClashBar.ConfigImport",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: message])
        }

        if let existing = try? Data(contentsOf: targetURL), existing == data {
            return false
        }

        try data.write(to: targetURL, options: .atomic)
        return true
    }

    private func validateClashConfigData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }

        let hasProxies = text.contains("proxies:")
        let hasProxyGroups = text.contains("proxy-groups:")
        let hasProxyProviders = text.contains("proxy-providers:")

        return hasProxies || hasProxyGroups || hasProxyProviders
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? (fallback ?? "") : trimmed
        let candidate = URL(fileURLWithPath: baseName).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else { return nil }

        let ext = (candidate as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            return "\(candidate).yaml"
        }
        guard ext == "yaml" || ext == "yml" else { return nil }
        return candidate
    }

    func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        let rawName = remoteURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { return "remote-config.yaml" }

        let ext = (rawName as NSString).pathExtension.lowercased()
        if ext == "yaml" || ext == "yml" {
            return rawName
        }

        if ext.isEmpty {
            return "\(rawName).yaml"
        }

        let stem = (rawName as NSString).deletingPathExtension
        let base = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "remote-config.yaml" : "\(base).yaml"
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // Subscription converters commonly branch on User-Agent: many of them generate a Clash
    // YAML only for known Clash clients, and answer other UAs with a base64 node list, a 502,
    // or nothing at all. They can also be slow (10s+ for a few thousand rules) or flaky, which
    // used to surface as "request timed out" / "not a valid Clash configuration".
    private static let fallbackSubscriptionUserAgents = ["clash-verge", "clash.meta/1.19.0"]
    private static let subscriptionDownloadAttempts = 2

    func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        let session = URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 60,
            timeoutIntervalForResource: 180))
        defer { session.finishTasksAndInvalidate() }

        var candidates: [String] = []
        if let userAgent {
            let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(trimmed)
            }
        }
        for agent in Self.fallbackSubscriptionUserAgents where !candidates.contains(agent) {
            candidates.append(agent)
        }

        var lastError: Error = NSError(
            domain: "ClashBar.ConfigImport",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Remote config download failed"])

        for attempt in 1...Self.subscriptionDownloadAttempts {
            for agent in candidates {
                do {
                    let data = try await self.fetchRemoteConfigData(
                        from: remoteURL,
                        userAgent: agent,
                        session: session)
                    guard self.validateClashConfigData(data) else {
                        lastError = self.invalidRemoteConfigResponseError(data)
                        continue
                    }
                    return data
                } catch {
                    lastError = error
                }
            }
            if attempt < Self.subscriptionDownloadAttempts {
                // The converter backend behind a subscription link is often rate limited or
                // still generating; give it a moment before the second round.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        throw lastError
    }

    private func fetchRemoteConfigData(
        from remoteURL: URL,
        userAgent: String,
        session: URLSession) async throws -> Data
    {
        var request = URLRequest(url: remoteURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Read the whole body at once. Iterating session.bytes byte-by-byte on a large
        // subscription (~700 KB) is slow enough to trip the request timeout.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw APIError.statusCode(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        guard data.count <= self.maxRemoteConfigBytes else {
            throw self.remoteConfigTooLargeError(limit: self.maxRemoteConfigBytes)
        }
        return data
    }

    private func invalidRemoteConfigResponseError(_ data: Data) -> NSError {
        let preview = String(data: data.prefix(160), encoding: .utf8) ?? "<binary data>"
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)

        // A very common shape: the backend ignored the requested format and returned the
        // base64 encoded node list used by v2rayN / Shadowrocket. Say so explicitly instead
        // of reporting a generic "not a Clash configuration".
        if let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
           let text = String(data: decoded.prefix(2048), encoding: .utf8),
           text.contains("://")
        {
            return NSError(
                domain: "ClashBar.ConfigImport",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: """
                The subscription returned a base64 node list (v2ray / Shadowrocket format) \
                instead of a Clash YAML. Make sure the link ends with a Clash target \
                (for example append &target=clash). Preview: \(trimmed)
                """])
        }

        return NSError(
            domain: "ClashBar.ConfigImport",
            code: 422,
            userInfo: [NSLocalizedDescriptionKey: """
            Remote config is not a Clash YAML (the subscription backend may have rejected \
            this User-Agent). Content preview: \(trimmed)
            """])
    }

    private func remoteConfigTooLargeError(limit: Int) -> NSError {
        NSError(
            domain: "ClashBar.ConfigImport",
            code: 413,
            userInfo: [NSLocalizedDescriptionKey: "Remote config exceeds size limit (\(limit) bytes)"])
    }
}

@MainActor
final class ConfigService {
    let configManager: ConfigDirectoryManager
    let configImportService: ConfigImportService

    init(
        configManager: ConfigDirectoryManager,
        configImportService: ConfigImportService)
    {
        self.configManager = configManager
        self.configImportService = configImportService
    }

    var configDirectory: URL? {
        self.configManager.configDirectory
    }

    var availableConfigs: [URL] {
        self.configManager.availableConfigs
    }

    var selectedConfig: URL? {
        self.configManager.selectedConfig
    }

    func chooseConfigDirectory() -> URL? {
        self.configManager.chooseConfigDirectory()
    }

    func setConfigDirectory(_ url: URL) {
        self.configManager.setConfigDirectory(url)
    }

    func selectConfig(_ url: URL) {
        self.configManager.selectConfig(url)
    }

    @discardableResult
    func reloadConfigs() -> [URL] {
        self.configManager.reloadConfigs()
    }

    func applyScannedConfigs(_ files: [URL]) {
        self.configManager.applyScannedConfigs(files)
    }

    @discardableResult
    func writeConfigData(_ data: Data, to targetURL: URL) throws -> Bool {
        try self.configImportService.writeConfigData(data, to: targetURL)
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        self.configImportService.normalizedConfigFileName(fileName, fallback: fallback)
    }

    func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        self.configImportService.inferredRemoteConfigFileName(from: remoteURL)
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        self.configImportService.isSupportedRemoteConfigURL(url)
    }

    func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        try await self.configImportService.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
    }
}
