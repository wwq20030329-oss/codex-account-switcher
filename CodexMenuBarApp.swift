import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

private enum Defaults {
    static let cliPath: String = {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEX_SWITCHER_CLI_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return override
        }

        if let bundledPath = Bundle.main.resourceURL?
            .appendingPathComponent("codex-account-switcher").path,
           FileManager.default.isExecutableFile(atPath: bundledPath)
        {
            return bundledPath
        }

        let localPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex-account-switcher").path
        return localPath
    }()
    static let githubCLIPath: String? = {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["GH_PATH"],
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
    static let profilesDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex-account-switcher", isDirectory: true)
    static let userInstalledAppURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Codex Account Switcher.app", isDirectory: true)
    static let systemInstalledAppURL = URL(fileURLWithPath: "/Applications/Codex Account Switcher.app", isDirectory: true)
    static let repositoryOwner = "wwq20030329-oss"
    static let repositoryName = "codex-account-switcher"
    static let repositoryURL = "https://github.com/\(repositoryOwner)/\(repositoryName)"
    static let releasesURL = "\(repositoryURL)/releases"
    static let latestReleaseAPIURL = "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest"
    static let usageURL = "https://chatgpt.com/codex/settings/usage"
    static let billingURL = "https://platform.openai.com/settings/organization/billing/overview"
    static let apiUsageURL = "https://platform.openai.com/usage"
}

private extension String {
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private enum AppMetadata {
    static var shortVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "dev"
        let buildVersion = info["CFBundleVersion"] as? String ?? "1"
        return "v\(shortVersion) (\(buildVersion))"
    }
}

private struct UsageWindow: Decodable, Hashable {
    let usedPercent: Int?
    let remainingPercent: Int?
    let resetAt: String?
    let resetAfterSeconds: Int?
}

private struct CreditsPayload: Decodable, Hashable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: Double?
}

private struct UsagePayload: Decodable, Hashable {
    let planDisplay: String?
    let planType: String?
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
    let usageUrl: String?
    let billingUrl: String?
    let credits: CreditsPayload?
    let checkedAt: String?
    let cached: Bool?
    let error: String?
    let stale: Bool?
    let source: String?
}

private struct ProfilePayload: Decodable, Identifiable, Hashable {
    let profileName: String
    let email: String?
    let name: String?
    let accountId: String?
    let usageSummary: String?
    let active: Bool
    let usage: UsagePayload?

    var id: String { profileName }

    var displayAccount: String {
        email ?? name ?? accountId ?? "未知账号"
    }

    var plan: String {
        if let display = usage?.planDisplay, !display.isEmpty {
            return display
        }
        if let type = usage?.planType, !type.isEmpty {
            return type.capitalized
        }
        if isAwaitingUsageFetch {
            return "未获取额度"
        }
        if usageError != nil {
            return "读取失败"
        }
        return "未获取额度"
    }

    var primaryRemaining: Int? {
        usage?.primaryWindow?.remainingPercent
    }

    var secondaryRemaining: Int? {
        usage?.secondaryWindow?.remainingPercent
    }

    var primaryUsed: Int? {
        usage?.primaryWindow?.usedPercent
    }

    var resetAt: String? {
        usage?.primaryWindow?.resetAt
    }

    var secondaryResetAt: String? {
        usage?.secondaryWindow?.resetAt
    }

    var usageError: String? {
        guard let error = usage?.error?.trimmingCharacters(in: .whitespacesAndNewlines),
              !error.isEmpty
        else {
            return nil
        }
        return error
    }

    var isAwaitingUsageFetch: Bool {
        guard let usage else {
            return true
        }
        if usage.source == "profile-cache" {
            return true
        }
        return usage.checkedAt == nil && usageError == nil && usage.planDisplay == nil && usage.planType == nil
    }

    var needsRepair: Bool {
        usageError != nil
    }

    var needsResaveRepair: Bool {
        guard let usageError else {
            return false
        }
        return usageError.contains("档案缺少登录快照")
    }

    var repairSummary: String? {
        guard let usageError else {
            return nil
        }
        if usageError.contains("档案缺少登录快照") {
            return "档案快照缺失，需要重新保存"
        }
        if usageError.contains("重新登录")
            || usageError.localizedCaseInsensitiveContains("401")
            || usageError.localizedCaseInsensitiveContains("403")
        {
            return "登录态可能失效，需要重新登录"
        }
        return "额度读取失败，可尝试修复"
    }

    var quotaState: QuotaState {
        guard let remaining = primaryRemaining else {
            return .unknown
        }
        if remaining <= 0 {
            return .empty
        }
        if remaining < 25 {
            return .tight
        }
        return .healthy
    }

    var quotaAlertLevel: QuotaAlertLevel {
        guard let remaining = primaryRemaining else {
            return .none
        }
        if remaining <= 0 {
            return .empty
        }
        if remaining <= 20 {
            return .low
        }
        return .none
    }

    var creditsText: String? {
        guard let credits = usage?.credits else {
            return nil
        }
        if credits.unlimited == true {
            return "Credits unlimited"
        }
        if credits.hasCredits == true {
            if let balance = credits.balance {
                return String(format: "Credits %.0f", balance)
            }
            return "Credits 可用"
        }
        return nil
    }

    var hasUsableQuota: Bool {
        if usage?.credits?.unlimited == true || usage?.credits?.hasCredits == true {
            return true
        }
        guard let primaryRemaining else {
            return false
        }
        return primaryRemaining >= 5
    }

    func matchesSearch(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        let normalized = trimmed.lowercased()
        let haystacks = [
            profileName,
            email,
            name,
            accountId,
            plan,
        ]
        .compactMap { $0?.lowercased() }
        return haystacks.contains { $0.contains(normalized) }
    }

    func matchesPlanFilter(_ filter: PlanFilter) -> Bool {
        filter.matches(plan: plan)
    }

    func settingActive(_ nextActive: Bool) -> ProfilePayload {
        ProfilePayload(
            profileName: profileName,
            email: email,
            name: name,
            accountId: accountId,
            usageSummary: usageSummary,
            active: nextActive,
            usage: usage
        )
    }
}

private struct CurrentAccountInfoPayload: Decodable, Hashable {
    let identityKey: String?
    let email: String?
    let name: String?
    let accountId: String?
}

private struct CurrentAccountPayload: Decodable, Hashable {
    let current: CurrentAccountInfoPayload?
    let managedName: String?
    let managed: Bool
}

private struct ReleasePayload: Decodable, Hashable {
    let tagName: String
    let name: String?
    let htmlURL: String
    let publishedAt: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case body
    }

    var displayVersion: String {
        VersionComparator.normalized(tagName)
    }
}

private enum QuotaState {
    case healthy
    case tight
    case empty
    case unknown

    var color: Color {
        switch self {
        case .healthy:
            return Color(red: 0.15, green: 0.59, blue: 0.42)
        case .tight:
            return Color(red: 0.88, green: 0.56, blue: 0.16)
        case .empty:
            return Color(red: 0.82, green: 0.22, blue: 0.22)
        case .unknown:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    var symbol: String {
        switch self {
        case .healthy:
            return "bolt.circle.fill"
        case .tight:
            return "hourglass.circle.fill"
        case .empty:
            return "exclamationmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .healthy:
            return "额度充足"
        case .tight:
            return "额度紧张"
        case .empty:
            return "5 小时已满"
        case .unknown:
            return "额度未知"
        }
    }
}

private enum QuotaAlertLevel: String {
    case none
    case low
    case empty
}

private enum SortMode: String {
    case smart
    case primaryRemaining

    var label: String {
        switch self {
        case .smart:
            return "智能"
        case .primaryRemaining:
            return "5h优先"
        }
    }
}

private enum PlanFilter: String, CaseIterable {
    case all
    case team
    case plus
    case other

    var label: String {
        switch self {
        case .all:
            return "全部"
        case .team:
            return "Team"
        case .plus:
            return "Plus"
        case .other:
            return "其他"
        }
    }

    func matches(plan: String) -> Bool {
        let normalized = plan.lowercased()
        switch self {
        case .all:
            return true
        case .team:
            return normalized.contains("team")
        case .plus:
            return normalized.contains("plus")
        case .other:
            return !normalized.contains("team") && !normalized.contains("plus")
        }
    }

    var next: PlanFilter {
        switch self {
        case .all:
            return .team
        case .team:
            return .plus
        case .plus:
            return .other
        case .other:
            return .all
        }
    }
}

private enum RefreshTimeFormatter {
    private static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private static let fallbackParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    static func label(from raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let date = parser.date(from: raw) ?? fallbackParser.date(from: raw)
        guard let date else {
            return nil
        }

        if Calendar.current.isDateInToday(date) {
            return "今天 \(timeFormatter.string(from: date))"
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "明天 \(timeFormatter.string(from: date))"
        }
        return monthDayTimeFormatter.string(from: date)
    }

    static func date(from raw: String?) -> Date? {
        guard let raw else {
            return nil
        }
        return parser.date(from: raw) ?? fallbackParser.date(from: raw)
    }

    static func countdownLabel(until raw: String?, now: Date = Date()) -> String? {
        guard let date = date(from: raw) else {
            return nil
        }

        let remainingSeconds = Int(date.timeIntervalSince(now))
        if remainingSeconds <= 0 {
            return "刚恢复"
        }

        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)小时\(minutes)分后"
        }
        if minutes > 0 {
            return "\(minutes)分钟后"
        }
        return "1分钟内"
    }

    static func freshnessLabel(checkedAt raw: String?, cached: Bool?, stale: Bool?, now: Date = Date()) -> String? {
        guard let checkedAt = date(from: raw) else {
            return nil
        }

        let elapsedSeconds = max(0, Int(now.timeIntervalSince(checkedAt)))
        let elapsedText: String
        if elapsedSeconds < 60 {
            elapsedText = "刚刚"
        } else if elapsedSeconds < 3600 {
            elapsedText = "\(elapsedSeconds / 60) 分钟前"
        } else {
            elapsedText = "\(elapsedSeconds / 3600) 小时前"
        }

        if stale == true {
            return "缓存 · \(elapsedText)"
        }
        if cached == true {
            return "已刷新 · \(elapsedText)"
        }
        return "实时 · \(elapsedText)"
    }
}

private enum SwitcherCLIError: LocalizedError {
    case executionFailed(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case let .executionFailed(message):
            return message
        case .invalidJSON:
            return "切换器返回的数据无法解析。"
        }
    }
}

private enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case requiresInstalledCopy
    case unavailable

    var menuLabel: String {
        switch self {
        case .enabled:
            return "关闭开机自启"
        case .disabled:
            return "开启开机自启"
        case .requiresApproval:
            return "关闭开机自启（待批准）"
        case .requiresInstalledCopy:
            return "请改用安装版开启"
        case .unavailable:
            return "开机自启不可用"
        }
    }

    var statusLabel: String {
        switch self {
        case .enabled:
            return "开机自启已开启"
        case .disabled:
            return "开机自启未开启"
        case .requiresApproval:
            return "开机自启待批准"
        case .requiresInstalledCopy:
            return "请从安装版运行"
        case .unavailable:
            return "开机自启不可用"
        }
    }
}

private enum VersionComparator {
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(from: lhs)
        let right = components(from: rhs)
        let maxCount = max(left.count, right.count)

        for index in 0..<maxCount {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue {
                return .orderedAscending
            }
            if leftValue > rightValue {
                return .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func components(from raw: String) -> [Int] {
        normalized(raw)
            .split(separator: ".")
            .map { chunk in
                let numeric = chunk.prefix { $0.isNumber }
                return Int(numeric) ?? 0
            }
    }
}

private enum UpdateCheckerError: LocalizedError {
    case noRelease
    case invalidPayload
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRelease:
            return "还没有可检查的正式发布版本。"
        case .invalidPayload:
            return "更新信息格式无法解析。"
        case let .requestFailed(message):
            return message
        }
    }
}

private enum SwitcherCLI {
    static func run(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Defaults.cliPath)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                let message = errorOutput.isEmpty ? output : errorOutput
                throw SwitcherCLIError.executionFailed(message.isEmpty ? "执行失败。" : message)
            }
            return output
        }.value
    }

    static func loadProfiles() async throws -> [ProfilePayload] {
        let json = try await run(["profiles-usage-json"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8) else {
            throw SwitcherCLIError.invalidJSON
        }
        return try decoder.decode([ProfilePayload].self, from: data)
    }

    static func loadCachedProfiles() async throws -> [ProfilePayload] {
        let json = try await run(["profiles-usage-cached-json"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8) else {
            throw SwitcherCLIError.invalidJSON
        }
        return try decoder.decode([ProfilePayload].self, from: data)
    }

    static func loadCurrentProfileUsage() async throws -> ProfilePayload? {
        let json = try await run(["current-profile-usage-json"])
        if json == "null" || json.isEmpty {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8) else {
            throw SwitcherCLIError.invalidJSON
        }
        return try decoder.decode(ProfilePayload.self, from: data)
    }

    static func loadCurrentAccount() async throws -> CurrentAccountPayload {
        let json = try await run(["current-json"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8) else {
            throw SwitcherCLIError.invalidJSON
        }
        return try decoder.decode(CurrentAccountPayload.self, from: data)
    }

    static func ensureCurrentSaved() async throws -> String {
        try await run(["ensure-current-saved"])
    }
}

private enum UpdateChecker {
    static func fetchLatestRelease() async throws -> ReleasePayload {
        do {
            return try await fetchFromGitHubAPI()
        } catch UpdateCheckerError.noRelease {
            if let release = try await fetchViaGitHubCLI() {
                return release
            }
            throw UpdateCheckerError.noRelease
        } catch {
            if let release = try await fetchViaGitHubCLI() {
                return release
            }
            throw error
        }
    }

    private static func fetchFromGitHubAPI() async throws -> ReleasePayload {
        guard let url = URL(string: Defaults.latestReleaseAPIURL) else {
            throw UpdateCheckerError.requestFailed("更新地址无效。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodexAccountSwitcher", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckerError.requestFailed("没有收到有效的更新响应。")
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(ReleasePayload.self, from: data)
            } catch {
                throw UpdateCheckerError.invalidPayload
            }
        case 404:
            throw UpdateCheckerError.noRelease
        default:
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateCheckerError.requestFailed(
                body.isEmpty
                    ? "检查更新失败（HTTP \(httpResponse.statusCode)）。"
                    : "检查更新失败（HTTP \(httpResponse.statusCode)）：\(body)"
            )
        }
    }

    private static func fetchViaGitHubCLI() async throws -> ReleasePayload? {
        guard let ghPath = Defaults.githubCLIPath else {
            return nil
        }

        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = [
                "api",
                "repos/\(Defaults.repositoryOwner)/\(Defaults.repositoryName)/releases/latest",
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                if errorOutput.localizedCaseInsensitiveContains("404") {
                    return nil
                }
                if errorOutput.localizedCaseInsensitiveContains("not found") {
                    return nil
                }
                throw UpdateCheckerError.requestFailed(
                    errorOutput.isEmpty ? "GitHub CLI 检查更新失败。" : errorOutput
                )
            }

            do {
                return try JSONDecoder().decode(ReleasePayload.self, from: outputData)
            } catch {
                throw UpdateCheckerError.invalidPayload
            }
        }.value
    }
}

private enum LoginItemManager {
    private static let appName = "Codex Account Switcher"

    static func isEnabled(for appURL: URL) -> Bool {
        (try? currentPaths())?.contains(appURL.standardizedFileURL.path) ?? false
    }

    static func register(appURL: URL) throws {
        let targetPath = appURL.standardizedFileURL.path.appleScriptEscaped
        let targetName = appName.appleScriptEscaped
        let script = """
        tell application "System Events"
            set targetPath to "\(targetPath)"
            set targetName to "\(targetName)"
            repeat with existingItem in login items
                try
                    if name of existingItem is targetName then
                        if POSIX path of (path of existingItem) is targetPath then
                            return "exists"
                        end if
                    end if
                end try
            end repeat
            make login item at end with properties {name:targetName, path:targetPath, hidden:false}
            return "added"
        end tell
        """
        _ = try runAppleScript(script)
    }

    static func unregister(appURL: URL) throws {
        let targetPath = appURL.standardizedFileURL.path.appleScriptEscaped
        let targetName = appName.appleScriptEscaped
        let script = """
        tell application "System Events"
            set targetPath to "\(targetPath)"
            set targetName to "\(targetName)"
            repeat with existingItem in (every login item)
                try
                    if name of existingItem is targetName or POSIX path of (path of existingItem) is targetPath then
                        delete existingItem
                    end if
                end try
            end repeat
            return "removed"
        end tell
        """
        _ = try runAppleScript(script)
    }

    private static func currentPaths() throws -> Set<String> {
        let script = """
        tell application "System Events"
            set outputLines to {}
            repeat with existingItem in (every login item)
                try
                    set end of outputLines to POSIX path of (path of existingItem)
                end try
            end repeat
            return outputLines as string
        end tell
        """
        let output = try runAppleScript(script)
        let parts = output
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    @discardableResult
    private static func runAppleScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw SwitcherCLIError.executionFailed(
                errorOutput.isEmpty ? "无法修改系统登录项。" : errorOutput
            )
        }

        return output
    }
}

@MainActor
private final class ProfileStore: ObservableObject {
    private static let autoRefreshInterval: TimeInterval = 180
    private static let automaticUpdateCheckInterval: TimeInterval = 86_400
    private static let lastQuotaAlertKey = "CodexSwitcher.lastQuotaAlertKey"
    private static let showUsableOnlyKey = "CodexSwitcher.showUsableOnly"
    private static let sortModeKey = "CodexSwitcher.sortMode"
    private static let accountWatchPollInterval: UInt64 = 2_000_000_000
    private static let lastUpdateCheckAtKey = "CodexSwitcher.lastUpdateCheckAt"
    private static let lastNotifiedReleaseKey = "CodexSwitcher.lastNotifiedRelease"

    @Published var profiles: [ProfilePayload] = []
    @Published var isLoading = false
    @Published var statusMessage: String?
    @Published var lastUpdated = Date()
    @Published var autoRefreshLabel = "自动刷新：每 3 分钟，仅当前账号"
    @Published var showUsableOnly = UserDefaults.standard.bool(forKey: showUsableOnlyKey)
    @Published var sortMode = SortMode(rawValue: UserDefaults.standard.string(forKey: sortModeKey) ?? "") ?? .smart
    @Published var isWatchingNewAccounts = false
    @Published var searchQuery = ""
    @Published var planFilter: PlanFilter = .all
    @Published var launchAtLoginState: LaunchAtLoginState = .unavailable
    @Published var latestAvailableVersion: String?

    private var autoRefreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshMode: RefreshMode?
    private var pendingRefreshSilent = true
    private var accountWatchTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var watchedIdentityKey: String?
    private let notificationCenter = UNUserNotificationCenter.current()

    init() {
        configureNotifications()
        refreshLaunchAtLoginState()
        startAutoRefresh()
        checkForUpdatesIfNeeded()
    }

    var orderedProfiles: [ProfilePayload] {
        let recommendedName = recommendedProfile?.profileName
        return profiles.sorted { left, right in
            if left.active != right.active {
                return left.active
            }
            if recommendedName != nil,
               left.profileName == recommendedName || right.profileName == recommendedName
            {
                return left.profileName == recommendedName
            }
            if left.hasUsableQuota != right.hasUsableQuota {
                return left.hasUsableQuota
            }
            switch sortMode {
            case .smart:
                let scoreDiff = profileScore(right) - profileScore(left)
                if scoreDiff != 0 {
                    return scoreDiff > 0
                }
            case .primaryRemaining:
                let leftPrimary = left.primaryRemaining ?? -1
                let rightPrimary = right.primaryRemaining ?? -1
                if leftPrimary != rightPrimary {
                    return leftPrimary > rightPrimary
                }
                let leftSecondary = left.secondaryRemaining ?? -1
                let rightSecondary = right.secondaryRemaining ?? -1
                if leftSecondary != rightSecondary {
                    return leftSecondary > rightSecondary
                }
            }
            return left.profileName.localizedCompare(right.profileName) == .orderedAscending
        }
    }

    var visibleProfiles: [ProfilePayload] {
        let filteredByAvailability = showUsableOnly ? orderedProfiles.filter(\.hasUsableQuota) : orderedProfiles
        return filteredByAvailability
            .filter { $0.matchesPlanFilter(planFilter) }
            .filter { $0.matchesSearch(searchQuery) }
    }

    var prioritizedProfiles: [ProfilePayload] {
        visibleProfiles.filter { $0.active || $0.hasUsableQuota }
    }

    var overflowProfiles: [ProfilePayload] {
        guard !showUsableOnly else {
            return []
        }
        return visibleProfiles.filter { !$0.active && !$0.hasUsableQuota }
    }

    var activeProfile: ProfilePayload? {
        profiles.first(where: \.active)
    }

    var totalProfileCount: Int {
        profiles.count
    }

    var usableProfileCount: Int {
        profiles.filter(\.hasUsableQuota).count
    }

    var unavailableProfileCount: Int {
        max(0, totalProfileCount - usableProfileCount)
    }

    var recommendedProfile: ProfilePayload? {
        let candidates = profiles.filter { !$0.active && $0.hasUsableQuota }
        switch sortMode {
        case .smart:
            return candidates.sorted { profileScore($0) > profileScore($1) }.first
        case .primaryRemaining:
            return candidates.sorted {
                let leftPrimary = $0.primaryRemaining ?? -1
                let rightPrimary = $1.primaryRemaining ?? -1
                if leftPrimary != rightPrimary {
                    return leftPrimary > rightPrimary
                }
                let leftSecondary = $0.secondaryRemaining ?? -1
                let rightSecondary = $1.secondaryRemaining ?? -1
                if leftSecondary != rightSecondary {
                    return leftSecondary > rightSecondary
                }
                return $0.profileName.localizedCompare($1.profileName) == .orderedAscending
            }.first
        }
    }

    var menuBarTitle: String {
        guard let activeProfile else {
            return "Codex"
        }
        guard let remaining = activeProfile.primaryRemaining else {
            return "Codex ?"
        }
        if remaining <= 0 {
            return "Codex 满"
        }
        return "Codex \(remaining)%"
    }

    var menuBarColor: Color {
        activeProfile?.quotaState.color ?? QuotaState.unknown.color
    }

    func refresh(silent: Bool = false) {
        refresh(mode: .cachedFull, silent: silent)
    }

    func refreshLive(silent: Bool = false) {
        refresh(mode: .liveAll, silent: silent)
    }

    func refreshCurrentOnly(silent: Bool = true) {
        refresh(mode: .currentOnly, silent: silent)
    }

    private func refresh(mode: RefreshMode, silent: Bool) {
        guard refreshTask == nil else {
            queueRefresh(mode: mode, silent: silent)
            return
        }
        let previousActiveProfile = activeProfile
        isLoading = true
        refreshTask = Task {
            defer {
                refreshTask = nil
                if let pending = dequeuePendingRefresh() {
                    refresh(mode: pending.mode, silent: pending.silent)
                } else {
                    isLoading = false
                }
            }
            do {
                let autoSavedMessage = try await SwitcherCLI.ensureCurrentSaved()
                switch mode {
                case .cachedFull:
                    let loaded = try await SwitcherCLI.loadCachedProfiles()
                    applyLoadedProfiles(loaded)
                    if let currentProfile = try await SwitcherCLI.loadCurrentProfileUsage() {
                        mergeCurrentProfile(currentProfile)
                    }
                case .liveAll:
                    let loaded = try await SwitcherCLI.loadProfiles()
                    applyLoadedProfiles(loaded)
                case .currentOnly:
                    if let currentProfile = try await SwitcherCLI.loadCurrentProfileUsage() {
                        mergeCurrentProfile(currentProfile)
                    } else {
                        let loaded = try await SwitcherCLI.loadCachedProfiles()
                        applyLoadedProfiles(loaded)
                    }
                }
                lastUpdated = Date()
                handleQuotaAlerts(previousActiveProfile: previousActiveProfile)
                if !autoSavedMessage.isEmpty {
                    setStatusMessage(autoSavedMessage, autoClearAfter: 4)
                } else if !silent {
                    setStatusMessage(nil)
                }
            } catch {
                setStatusMessage(error.localizedDescription)
            }
        }
    }

    func dismissStatusMessage() {
        setStatusMessage(nil)
    }

    private func setStatusMessage(_ message: String?, autoClearAfter: TimeInterval? = nil) {
        statusClearTask?.cancel()
        statusClearTask = nil
        statusMessage = message

        guard let message, let autoClearAfter else {
            return
        }

        statusClearTask = Task { [weak self] in
            let duration = UInt64(autoClearAfter * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            await MainActor.run {
                guard self?.statusMessage == message else {
                    return
                }
                self?.statusMessage = nil
                self?.statusClearTask = nil
            }
        }
    }

    private func queueRefresh(mode: RefreshMode, silent: Bool) {
        if let existingMode = pendingRefreshMode {
            pendingRefreshMode = preferredRefreshMode(existingMode, mode)
            pendingRefreshSilent = pendingRefreshSilent && silent
            return
        }
        pendingRefreshMode = mode
        pendingRefreshSilent = silent
    }

    private func dequeuePendingRefresh() -> (mode: RefreshMode, silent: Bool)? {
        guard let mode = pendingRefreshMode else {
            return nil
        }
        let silent = pendingRefreshSilent
        pendingRefreshMode = nil
        pendingRefreshSilent = true
        return (mode, silent)
    }

    func saveCurrent() {
        let defaultName = activeProfile?.profileName ?? "当前账号"
        guard let name = PromptCenter.textInput(
            title: "保存当前账号",
            message: "给当前登录的 Codex 账号起个名字。",
            defaultValue: defaultName
        ) else {
            return
        }
        runAction(arguments: ["save", name], successTitle: "账号档案已保存")
    }

    func toggleContinuousAddMode() {
        if isWatchingNewAccounts {
            stopContinuousAddMode(notify: true)
            return
        }

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let autoSavedMessage = try await SwitcherCLI.ensureCurrentSaved()
                let currentAccount = try await SwitcherCLI.loadCurrentAccount()
                watchedIdentityKey = currentAccount.current?.identityKey
                isWatchingNewAccounts = true
                closeMenuWindow()

                let baselineName = currentAccount.current?.email
                    ?? currentAccount.current?.name
                    ?? currentAccount.current?.accountId
                    ?? "当前账号"
                setStatusMessage(
                    autoSavedMessage.isEmpty
                        ? "连续添加已开启。现在去 Codex 登录下一个账号，我会自动保存。"
                        : autoSavedMessage,
                    autoClearAfter: 6
                )
                postNotification(
                    title: "连续添加已开启",
                    body: "当前基准账号：\(baselineName)。你继续登录新账号时，我会自动加入切换器。"
                )
                startAccountWatchLoop()
            } catch {
                setStatusMessage(error.localizedDescription)
                PromptCenter.info(title: "无法开启连续添加", message: error.localizedDescription)
            }
        }
    }

    func quickSwitch() {
        guard let recommendedProfile else {
            setStatusMessage("暂时没有可直接接力的可用账号。", autoClearAfter: 4)
            return
        }
        switchTo(recommendedProfile)
    }

    func toggleUsableOnly() {
        showUsableOnly.toggle()
        UserDefaults.standard.set(showUsableOnly, forKey: Self.showUsableOnlyKey)
    }

    func toggleSortMode() {
        sortMode = sortMode == .smart ? .primaryRemaining : .smart
        UserDefaults.standard.set(sortMode.rawValue, forKey: Self.sortModeKey)
    }

    func cyclePlanFilter() {
        planFilter = planFilter.next
    }

    func clearSearch() {
        searchQuery = ""
    }

    func stopContinuousAddMode(notify: Bool = false) {
        accountWatchTask?.cancel()
        accountWatchTask = nil
        watchedIdentityKey = nil
        isWatchingNewAccounts = false
        if notify {
            setStatusMessage("连续添加已停止。", autoClearAfter: 4)
        }
    }

    func switchTo(_ profile: ProfilePayload) {
        setStatusMessage("正在切换到 \(profile.profileName)...")
        closeMenuWindow()
        runAction(arguments: ["switch", profile.profileName], showSuccessAlert: false)
    }

    func rename(_ profile: ProfilePayload) {
        guard let nextName = PromptCenter.textInput(
            title: "重命名档案",
            message: "给这个账号档案起个更容易区分的名字。",
            defaultValue: profile.profileName
        ) else {
            return
        }
        runAction(arguments: ["rename", profile.profileName, nextName], successTitle: "档案已重命名")
    }

    func delete(_ profile: ProfilePayload) {
        let confirmed = PromptCenter.confirm(
            title: "确认删除档案",
            message: "将删除“\(profile.profileName)”。它会从切换器中移除，但不会注销账号。"
        )
        guard confirmed else {
            return
        }
        runAction(arguments: ["delete", profile.profileName], successTitle: "档案已删除")
    }

    func openUsagePage() {
        openURL(activeProfile?.usage?.usageUrl ?? Defaults.usageURL)
    }

    func openBilling() {
        openURL(activeProfile?.usage?.billingUrl ?? Defaults.billingURL)
        openURL(Defaults.apiUsageURL)
    }

    func openReleasesPage() {
        openURL(Defaults.releasesURL)
    }

    func openProfilesDirectory() {
        NSWorkspace.shared.open(Defaults.profilesDirectoryURL)
    }

    private var currentAppURL: URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private var preferredInstalledAppURL: URL? {
        let candidates = [
            Defaults.userInstalledAppURL,
            Defaults.systemInstalledAppURL,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private var isRunningInstalledCopy: Bool {
        guard let installedURL = preferredInstalledAppURL else {
            return false
        }
        return currentAppURL == installedURL
    }

    func openInstalledApp(terminateCurrent: Bool = false) {
        guard let installedURL = preferredInstalledAppURL else {
            setStatusMessage("没有找到安装版。请先打开 ~/Applications 里的 Codex Account Switcher。", autoClearAfter: 6)
            return
        }

        NSWorkspace.shared.openApplication(at: installedURL, configuration: .init()) { _, _ in
            guard terminateCurrent else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        }
    }

    func openCodexApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
            return
        }
        if let fallbackURL = URL(string: "file:///Applications/Codex.app") {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    func showAbout() {
        PromptCenter.info(
            title: "Codex Account Switcher",
            message: "\(AppMetadata.versionLabel)\n\n本地菜单栏工具，用来保存和切换 Codex 账号档案。\n\n档案目录：\(Defaults.profilesDirectoryURL.path)\n发布页：\(Defaults.releasesURL)"
        )
    }

    func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            setStatusMessage("当前系统不支持开机自启管理。", autoClearAfter: 5)
            return
        }

        guard isRunningInstalledCopy else {
            let shouldOpenInstalled = PromptCenter.confirmAction(
                title: "请改用安装版",
                message: "你现在打开的是桌面副本，macOS 对这类副本的开机自启支持不稳定。\n\n我建议直接打开 ~/Applications 里的安装版，再在那里开启开机自启。",
                confirmTitle: "打开安装版",
                cancelTitle: "取消"
            )
            guard shouldOpenInstalled else {
                return
            }
            openInstalledApp(terminateCurrent: true)
            setStatusMessage("已切到安装版。请在新打开的窗口里再次点“开机自启”。", autoClearAfter: 6)
            return
        }

        do {
            let service = SMAppService.mainApp
            switch launchAtLoginState {
            case .enabled, .requiresApproval:
                if service.status == .notFound {
                    try LoginItemManager.unregister(appURL: currentAppURL)
                } else {
                    try service.unregister()
                }
                refreshLaunchAtLoginState()
                setStatusMessage("已关闭开机自启。", autoClearAfter: 5)
            case .disabled:
                if service.status == .notFound {
                    try LoginItemManager.register(appURL: currentAppURL)
                    refreshLaunchAtLoginState()
                    setStatusMessage("已通过系统登录项开启开机自启。", autoClearAfter: 5)
                } else {
                    try service.register()
                    refreshLaunchAtLoginState()
                    switch launchAtLoginState {
                    case .requiresApproval:
                        setStatusMessage("已请求开启开机自启，请在系统设置的“登录项”中允许它。", autoClearAfter: 6)
                        PromptCenter.info(
                            title: "开机自启待系统批准",
                            message: "我已经请求开启开机自启。请到“系统设置 > 通用 > 登录项”里允许 Codex Account Switcher。"
                        )
                    case .enabled:
                        setStatusMessage("已开启开机自启。", autoClearAfter: 5)
                    case .disabled, .requiresInstalledCopy, .unavailable:
                        setStatusMessage("开机自启设置已更新。", autoClearAfter: 5)
                    }
                }
            case .requiresInstalledCopy:
                setStatusMessage("请先切到安装版，再开启开机自启。", autoClearAfter: 5)
            case .unavailable:
                setStatusMessage("当前构建环境暂不支持开机自启。", autoClearAfter: 5)
            }
        } catch {
            do {
                switch launchAtLoginState {
                case .enabled, .requiresApproval:
                    try LoginItemManager.unregister(appURL: currentAppURL)
                    refreshLaunchAtLoginState()
                    setStatusMessage("已通过系统登录项关闭开机自启。", autoClearAfter: 5)
                case .disabled:
                    try LoginItemManager.register(appURL: currentAppURL)
                    refreshLaunchAtLoginState()
                    setStatusMessage("已通过系统登录项开启开机自启。", autoClearAfter: 5)
                case .requiresInstalledCopy, .unavailable:
                    throw error
                }
            } catch {
                setStatusMessage("设置开机自启失败：\(error.localizedDescription)")
                PromptCenter.info(title: "无法设置开机自启", message: error.localizedDescription)
            }
        }
    }

    func checkForUpdates(manual: Bool = true) {
        if updateCheckTask != nil {
            if manual {
                setStatusMessage("正在检查更新，请稍候。", autoClearAfter: 3)
            }
            return
        }

        updateCheckTask = Task {
            defer { updateCheckTask = nil }
            do {
                let release = try await UpdateChecker.fetchLatestRelease()
                UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckAtKey)
                latestAvailableVersion = nil

                if VersionComparator.isNewer(release.displayVersion, than: AppMetadata.shortVersion) {
                    latestAvailableVersion = release.displayVersion
                    let current = AppMetadata.shortVersion
                    let message = "发现新版本 \(release.displayVersion)，当前是 \(current)。"
                    setStatusMessage(message, autoClearAfter: 6)

                    let notifiedKey = UserDefaults.standard.string(forKey: Self.lastNotifiedReleaseKey)
                    if notifiedKey != release.displayVersion {
                        postNotification(
                            title: "Codex Account Switcher 有新版本",
                            body: "\(release.displayVersion) 已可用。"
                        )
                        UserDefaults.standard.set(release.displayVersion, forKey: Self.lastNotifiedReleaseKey)
                    }

                    if manual {
                        let shouldOpen = PromptCenter.confirmAction(
                            title: "发现新版本 \(release.displayVersion)",
                            message: "当前版本是 \(AppMetadata.shortVersion)。现在打开发布页吗？",
                            confirmTitle: "打开发布页",
                            cancelTitle: "稍后"
                        )
                        if shouldOpen {
                            openURL(release.htmlURL)
                        }
                    }
                } else if manual {
                    setStatusMessage("当前已经是最新版本 \(AppMetadata.shortVersion)。", autoClearAfter: 5)
                }
            } catch {
                if manual {
                    let message = error.localizedDescription
                    setStatusMessage(message)
                    PromptCenter.info(title: "检查更新失败", message: message)
                }
            }
        }
    }

    func exportBackup() {
        let defaultName = "codex-account-switcher-backup-\(Self.timestampForFilename()).zip"
        guard let path = PromptCenter.savePath(
            title: "导出账号档案备份",
            message: "导出当前所有账号档案和切换器状态，方便换机器或手动备份。",
            defaultFilename: defaultName
        ) else {
            return
        }
        runAction(arguments: ["export-backup", path], successTitle: "备份已导出")
    }

    func repair(_ profile: ProfilePayload) {
        let hint = profile.repairSummary ?? "这个账号的额度信息当前读取失败。"

        if profile.active && profile.needsResaveRepair {
            let shouldResave = PromptCenter.confirmAction(
                title: "修复当前账号档案",
                message: "\(hint)\n\n我会重新保存当前账号到同名档案里。",
                confirmTitle: "重新保存",
                cancelTitle: "取消"
            )
            guard shouldResave else {
                return
            }
            runAction(
                arguments: ["save", "--force", profile.profileName],
                showSuccessAlert: false,
                successTitle: "档案已修复"
            )
            return
        }

        if profile.active {
            let shouldOpenCodex = PromptCenter.confirmAction(
                title: "修复当前账号",
                message: "\(hint)\n\n我会先打开 Codex。如果出现登录页，请完成登录后回到切换器点“刷新”。",
                confirmTitle: "打开 Codex",
                cancelTitle: "取消"
            )
            guard shouldOpenCodex else {
                return
            }
            openCodexApp()
            setStatusMessage("已打开 Codex。完成登录后回到这里点刷新；如果已经登录正常，也可以重新保存当前账号。", autoClearAfter: 8)
            return
        }

        let shouldSwitch = PromptCenter.confirmAction(
            title: "修复账号档案",
            message: "\(hint)\n\n我会先切换到“\(profile.profileName)”，并重新打开 Codex。如果出现登录页，请完成登录后再回到切换器点刷新。",
            confirmTitle: "切换并修复",
            cancelTitle: "取消"
        )
        guard shouldSwitch else {
            return
        }
        switchTo(profile)
    }

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshLaunchAtLoginState() {
        guard #available(macOS 13.0, *) else {
            launchAtLoginState = .unavailable
            return
        }

        guard isRunningInstalledCopy else {
            launchAtLoginState = .requiresInstalledCopy
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginState = .enabled
        case .notRegistered:
            launchAtLoginState = .disabled
        case .requiresApproval:
            launchAtLoginState = .requiresApproval
        case .notFound:
            launchAtLoginState = LoginItemManager.isEnabled(for: currentAppURL) ? .enabled : .disabled
        @unknown default:
            launchAtLoginState = .unavailable
        }
    }

    private func checkForUpdatesIfNeeded() {
        let lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastUpdateCheckAtKey) as? Date
        if let lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < Self.automaticUpdateCheckInterval
        {
            return
        }
        checkForUpdates(manual: false)
    }

    private func startAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentOnly(silent: true)
            }
        }
        autoRefreshTimer?.tolerance = 10
    }

    private func configureNotifications() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func handleQuotaAlerts(previousActiveProfile: ProfilePayload?) {
        guard let currentActiveProfile = activeProfile else {
            UserDefaults.standard.removeObject(forKey: Self.lastQuotaAlertKey)
            return
        }

        let previousLevel = previousActiveProfile?.quotaAlertLevel ?? .none
        let currentLevel = currentActiveProfile.quotaAlertLevel
        let storedKey = UserDefaults.standard.string(forKey: Self.lastQuotaAlertKey)
        let currentKey = "\(currentActiveProfile.profileName)::\(currentLevel.rawValue)"

        if currentLevel == .none {
            if let previousActiveProfile,
               previousActiveProfile.profileName == currentActiveProfile.profileName,
               previousLevel != .none,
               let remaining = currentActiveProfile.primaryRemaining
            {
                postNotification(
                    title: "Codex 额度已恢复",
                    body: "\(currentActiveProfile.profileName) 的 5 小时额度已恢复到 \(remaining)%。"
                )
            }
            UserDefaults.standard.removeObject(forKey: Self.lastQuotaAlertKey)
            return
        }

        guard storedKey != currentKey else {
            return
        }

        let recommendationText: String
        if let recommendedProfile, !recommendedProfile.active {
            recommendationText = " 可切到 \(recommendedProfile.profileName)。"
        } else {
            recommendationText = ""
        }

        let body: String
        switch currentLevel {
        case .low:
            let remaining = currentActiveProfile.primaryRemaining ?? 0
            body = "\(currentActiveProfile.profileName) 的 5 小时额度只剩 \(remaining)%。\(recommendationText)"
        case .empty:
            body = "\(currentActiveProfile.profileName) 的 5 小时额度已满。\((recommendationText))"
        case .none:
            return
        }

        postNotification(
            title: currentLevel == .empty ? "Codex 额度已满" : "Codex 额度偏低",
            body: body
        )
        UserDefaults.standard.set(currentKey, forKey: Self.lastQuotaAlertKey)
    }

    private func startAccountWatchLoop() {
        accountWatchTask?.cancel()
        accountWatchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.accountWatchPollInterval)
                do {
                    let currentAccount = try await SwitcherCLI.loadCurrentAccount()
                    guard let current = currentAccount.current,
                          let currentIdentityKey = current.identityKey
                    else {
                        continue
                    }
                    guard currentIdentityKey != watchedIdentityKey else {
                        continue
                    }

                    watchedIdentityKey = currentIdentityKey
                    let autoSavedMessage = try await SwitcherCLI.ensureCurrentSaved()
                    let displayName = current.email ?? current.name ?? current.accountId ?? "新账号"
                    let loaded = try await SwitcherCLI.loadCachedProfiles()
                    applyLoadedProfiles(loaded)
                    if let currentProfile = try await SwitcherCLI.loadCurrentProfileUsage() {
                        mergeCurrentProfile(currentProfile)
                    }

                    lastUpdated = Date()
                    setStatusMessage(
                        autoSavedMessage.isEmpty
                            ? "已识别并保存 \(displayName)。继续登录下一个账号也会自动保存。"
                            : autoSavedMessage,
                        autoClearAfter: 6
                    )
                    postNotification(
                        title: "新账号已自动保存",
                        body: "\(displayName) 已加入切换器。你可以继续登录下一个账号。"
                    )
                } catch {
                    // Ignore transient states while the user is mid-login or temporarily logged out.
                }
            }
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex-switcher.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private static func timestampForFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func applyLoadedProfiles(_ loaded: [ProfilePayload]) {
        let activeName = loaded.first(where: \.active)?.profileName
        if let activeName {
            profiles = loaded.map { $0.settingActive($0.profileName == activeName) }
        } else {
            profiles = loaded
        }
    }

    private func mergeCurrentProfile(_ profile: ProfilePayload) {
        let currentName = profile.profileName
        profiles = profiles.map { existing in
            if existing.profileName == currentName {
                return profile.settingActive(true)
            }
            return existing.settingActive(false)
        }
        if !profiles.contains(where: { $0.profileName == currentName }) {
            profiles.append(profile.settingActive(true))
        }
    }

    private func closeMenuWindow() {
        NSApp.keyWindow?.close()
    }

    private func runAction(arguments: [String], showSuccessAlert: Bool = true, successTitle: String = "已完成") {
        isLoading = true
        Task {
            do {
                let output = try await SwitcherCLI.run(arguments)
                lastUpdated = Date()
                setStatusMessage(output.isEmpty ? "已完成。" : output, autoClearAfter: 5)
                refresh(silent: true)
                if showSuccessAlert {
                    PromptCenter.info(title: successTitle, message: output.isEmpty ? "已完成。" : output)
                }
            } catch {
                setStatusMessage(error.localizedDescription)
                PromptCenter.info(title: "操作失败", message: error.localizedDescription)
            }
            isLoading = false
        }
    }

    private func profileScore(_ profile: ProfilePayload) -> Int {
        let primary = profile.primaryRemaining ?? -1
        let secondary = profile.secondaryRemaining ?? -1
        let credits = profile.usage?.credits
        var score = max(0, primary) * 1000 + max(0, secondary) * 10
        if credits?.unlimited == true {
            score += 1_000_000
        } else if credits?.hasCredits == true {
            score += 5_000
        }
        return score
    }

    private func preferredRefreshMode(_ left: RefreshMode, _ right: RefreshMode) -> RefreshMode {
        refreshPriority(left) >= refreshPriority(right) ? left : right
    }

    private func refreshPriority(_ mode: RefreshMode) -> Int {
        switch mode {
        case .liveAll:
            return 3
        case .cachedFull:
            return 2
        case .currentOnly:
            return 1
        }
    }

    private enum RefreshMode {
        case cachedFull
        case liveAll
        case currentOnly
    }
}

private enum PromptCenter {
    @discardableResult
    static func info(title: String, message: String) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        return alert.runModal()
    }

    static func textInput(title: String, message: String, defaultValue: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func confirm(title: String, message: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmAction(title: String, message: String, confirmTitle: String, cancelTitle: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func savePath(title: String, message: String, defaultFilename: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = title
        panel.message = message
        panel.nameFieldStringValue = defaultFilename
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        let response = panel.runModal()
        guard response == .OK else {
            return nil
        }
        return panel.url?.path
    }
}

private struct MetricBadge: View {
    let title: String
    let value: String
    let tint: Color
    var titleColor: Color = Color(nsColor: .secondaryLabelColor)
    var background: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(titleColor)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(background ?? tint.opacity(0.10))
        )
    }
}

private struct CompactMetricChip: View {
    let title: String
    let value: String
    let tint: Color
    let background: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(background)
        )
    }
}

private struct ActionChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary : .white)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(disabled ? Color.secondary.opacity(0.12) : tint)
        )
        .disabled(disabled)
    }
}

private struct QuotaBar: View {
    let title: String
    let remaining: Int?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.07))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .frame(height: 7)
        }
    }

    private var ratio: CGFloat {
        guard let remaining else {
            return 0.16
        }
        return CGFloat(max(0, min(remaining, 100))) / 100
    }

    private var label: String {
        guard let remaining else {
            return "未知"
        }
        if remaining <= 0 {
            return "已满"
        }
        return "剩余 \(remaining)%"
    }
}

private struct ProfileCard: View {
    let profile: ProfilePayload
    let recommended: Bool
    let onSwitch: () -> Void
    let onRepair: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var isDeemphasized: Bool {
        !profile.active && !profile.hasUsableQuota
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.profileName)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text(profile.displayAccount)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 6) {
                    Tag(text: profile.plan, tint: profile.quotaState.color.opacity(0.18), foreground: profile.quotaState.color)
                    if profile.active {
                        Tag(text: "当前", tint: Color.blue.opacity(0.14), foreground: .blue)
                    } else if recommended {
                        Tag(text: "推荐", tint: Color.green.opacity(0.14), foreground: .green)
                    }
                }
            }

            HStack(spacing: 8) {
                Label(profile.quotaState.label, systemImage: profile.quotaState.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(profile.quotaState.color)

                CompactMetricChip(
                    title: "5h",
                    value: compactQuotaLabel(profile.primaryRemaining),
                    tint: profile.quotaState.color,
                    background: profile.quotaState.color.opacity(0.12)
                )

                CompactMetricChip(
                    title: "周",
                    value: compactQuotaLabel(profile.secondaryRemaining),
                    tint: Color(red: 0.22, green: 0.48, blue: 0.82),
                    background: Color(red: 0.22, green: 0.48, blue: 0.82).opacity(0.12)
                )

                if let credits = profile.creditsText {
                    CompactMetricChip(
                        title: "Credits",
                        value: credits.replacingOccurrences(of: "Credits ", with: ""),
                        tint: Color(red: 0.34, green: 0.38, blue: 0.43),
                        background: Color.black.opacity(0.05)
                    )
                }

                Spacer(minLength: 4)

                Button(profile.active ? "当前" : "切换") {
                    onSwitch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(profile.active)

                if profile.needsRepair {
                    Button("修复") {
                        onRepair()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(Color(red: 0.90, green: 0.48, blue: 0.12))
                }

                Menu {
                    Button("重命名档案", action: onRename)
                    Button("删除档案", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .menuStyle(.borderlessButton)
            }

            if let refreshSummary = refreshSummary {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text(refreshSummary)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            if let freshnessSummary = freshnessSummary {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 10, weight: .semibold))
                    Text(freshnessSummary)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }

            if let repairSummary = profile.repairSummary ?? profile.usageError {
                HStack(spacing: 6) {
                    Image(systemName: profile.needsResaveRepair ? "square.and.arrow.down.on.square" : "wrench.and.screwdriver.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(repairSummary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.22))
                .help(profile.usageError ?? repairSummary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isDeemphasized ? Color(nsColor: .textBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isDeemphasized ? 0.01 : 0.04), radius: isDeemphasized ? 2 : 6, x: 0, y: isDeemphasized ? 1 : 3)
        .opacity(isDeemphasized ? 0.64 : 1)
    }

    private var borderColor: Color {
        if profile.active {
            return Color.blue.opacity(0.35)
        }
        if recommended {
            return Color.green.opacity(0.28)
        }
        return Color.black.opacity(isDeemphasized ? 0.04 : 0.08)
    }

    private var refreshSummary: String? {
        let pieces = [
            refreshPiece(title: "5h", resetAt: profile.resetAt),
            refreshPiece(title: "周", resetAt: profile.secondaryResetAt),
        ].compactMap { $0 }
        if pieces.isEmpty {
            return nil
        }
        return pieces.joined(separator: "  ·  ")
    }

    private var freshnessSummary: String? {
        RefreshTimeFormatter.freshnessLabel(
            checkedAt: profile.usage?.checkedAt,
            cached: profile.usage?.cached,
            stale: profile.usage?.stale
        )
    }

    private func refreshPiece(title: String, resetAt: String?) -> String? {
        guard let refreshLabel = RefreshTimeFormatter.label(from: resetAt) else {
            return nil
        }
        if let countdown = RefreshTimeFormatter.countdownLabel(until: resetAt) {
            return "\(title) 刷新 \(refreshLabel)（\(countdown)）"
        }
        return "\(title) 刷新 \(refreshLabel)"
    }

    private func compactQuotaLabel(_ remaining: Int?) -> String {
        guard let remaining else {
            if profile.isAwaitingUsageFetch {
                return "待刷"
            }
            if profile.usageError != nil {
                return "失败"
            }
            return "待刷"
        }
        if remaining <= 0 {
            return "已满"
        }
        return "\(remaining)%"
    }
}

private struct Tag: View {
    let text: String
    let tint: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Capsule().fill(tint))
            .foregroundStyle(foreground)
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}

private struct HeaderCard: View {
    let activeProfile: ProfilePayload?
    let recommendedProfile: ProfilePayload?
    let lastUpdated: Date
    let totalCount: Int
    let usableCount: Int
    let unavailableCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前账号概览")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.10, green: 0.18, blue: 0.24))
                }
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.42, green: 0.47, blue: 0.52))
                }
                .buttonStyle(.plain)
                .help("退出")

                Text(lastUpdated.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.34, green: 0.41, blue: 0.46))
            }

            if let activeProfile {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeProfile.profileName)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color(red: 0.08, green: 0.17, blue: 0.22))
                            .lineLimit(1)
                        Text(activeProfile.displayAccount)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 0.31, green: 0.38, blue: 0.43))
                            .lineLimit(1)
                    }
                    Spacer()
                    Tag(
                        text: activeProfile.plan,
                        tint: Color.white.opacity(0.95),
                        foreground: Color(red: 0.10, green: 0.18, blue: 0.24)
                    )
                    Tag(
                        text: activeProfile.quotaState.label,
                        tint: activeProfile.quotaState.color.opacity(0.16),
                        foreground: activeProfile.quotaState.color
                    )
                }

                HStack(spacing: 10) {
                    MetricBadge(
                        title: "5 小时",
                        value: quotaLabel(for: activeProfile.primaryRemaining),
                        tint: activeProfile.quotaState.color,
                        titleColor: Color(red: 0.35, green: 0.41, blue: 0.45),
                        background: activeProfile.quotaState.color.opacity(0.14)
                    )
                    MetricBadge(
                        title: "本周",
                        value: quotaLabel(for: activeProfile.secondaryRemaining),
                        tint: Color(red: 0.22, green: 0.48, blue: 0.82),
                        titleColor: Color(red: 0.35, green: 0.41, blue: 0.45),
                        background: Color(red: 0.22, green: 0.48, blue: 0.82).opacity(0.12)
                    )
                }

                HStack(spacing: 8) {
                    CompactMetricChip(
                        title: "总账号",
                        value: "\(totalCount)",
                        tint: Color(red: 0.18, green: 0.24, blue: 0.34),
                        background: Color.black.opacity(0.05)
                    )
                    CompactMetricChip(
                        title: "可用",
                        value: "\(usableCount)",
                        tint: Color(red: 0.15, green: 0.59, blue: 0.42),
                        background: Color(red: 0.15, green: 0.59, blue: 0.42).opacity(0.12)
                    )
                    CompactMetricChip(
                        title: "不可用",
                        value: "\(unavailableCount)",
                        tint: Color(red: 0.82, green: 0.22, blue: 0.22),
                        background: Color(red: 0.82, green: 0.22, blue: 0.22).opacity(0.10)
                    )
                }

                if let recommendedProfile {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("推荐：\(recommendedProfile.profileName)  \(recommendedProfile.usageSummary ?? "额度未知")")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.24, green: 0.30, blue: 0.18))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(red: 0.96, green: 0.95, blue: 0.83))
                    )
                }
            } else {
                Text("当前还没有读取到可用账号。")
                    .foregroundStyle(Color(red: 0.34, green: 0.41, blue: 0.46))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.97, blue: 0.92),
                            Color(red: 0.92, green: 0.97, blue: 0.93),
                            Color(red: 0.91, green: 0.95, blue: 0.98),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func quotaLabel(for remaining: Int?) -> String {
        guard let remaining else {
            return "未知"
        }
        if remaining <= 0 {
            return "已满"
        }
        return "剩余 \(remaining)%"
    }
}

private struct DashboardView: View {
    @ObservedObject var store: ProfileStore

    var body: some View {
        VStack(spacing: 12) {
            HeaderCard(
                activeProfile: store.activeProfile,
                recommendedProfile: store.recommendedProfile,
                lastUpdated: store.lastUpdated,
                totalCount: store.totalProfileCount,
                usableCount: store.usableProfileCount,
                unavailableCount: store.unavailableProfileCount
            )

            if let statusMessage = store.statusMessage, !statusMessage.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        store.dismissStatusMessage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    .buttonStyle(.plain)
                    .help("关闭提示")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
            }

            HStack(spacing: 10) {
                TextField("搜索档案、邮箱、套餐", text: $store.searchQuery)
                    .textFieldStyle(.roundedBorder)

                Button("套餐：\(store.planFilter.label)") {
                    store.cyclePlanFilter()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                if !store.searchQuery.isEmpty {
                    Button("清空") {
                        store.clearSearch()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .font(.system(size: 11, weight: .medium))

            HStack(spacing: 10) {
                ActionChip(
                    title: "切到最优账号",
                    systemImage: "arrow.triangle.2.circlepath.circle.fill",
                    tint: Color(red: 0.16, green: 0.47, blue: 0.67),
                    disabled: store.recommendedProfile == nil,
                    action: store.quickSwitch
                )
                ActionChip(
                    title: "保存当前账号",
                    systemImage: "square.and.arrow.down.fill",
                    tint: Color(red: 0.15, green: 0.59, blue: 0.42),
                    action: store.saveCurrent
                )
                ActionChip(
                    title: "刷新",
                    systemImage: "arrow.clockwise",
                    tint: Color(red: 0.24, green: 0.27, blue: 0.33),
                    action: { store.refreshLive() }
                )
            }

            HStack(spacing: 10) {
                Menu {
                    Button(store.isWatchingNewAccounts ? "停止连续添加" : "连续添加账号") {
                        store.toggleContinuousAddMode()
                    }

                    Button(store.launchAtLoginState.menuLabel) {
                        store.toggleLaunchAtLogin()
                    }
                    .disabled(store.launchAtLoginState == .unavailable)

                    Divider()

                    Button("切换排序：\(store.sortMode.label)") {
                        store.toggleSortMode()
                    }

                    Button(store.showUsableOnly ? "显示全部账号" : "只看可用账号") {
                        store.toggleUsableOnly()
                    }

                    Button("导出备份") {
                        store.exportBackup()
                    }

                    Divider()

                    Button("打开档案目录") {
                        store.openProfilesDirectory()
                    }

                    Button("打开 Codex 用量页") {
                        store.openUsagePage()
                    }

                    Button("打开账单") {
                        store.openBilling()
                    }

                    Button("检查更新") {
                        store.checkForUpdates()
                    }

                    Button("打开发布页") {
                        store.openReleasesPage()
                    }

                    Divider()

                    Button("关于此 App") {
                        store.showAbout()
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)

                Spacer()

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .keyboardShortcut("q")
            }
            .font(.system(size: 11, weight: .medium))

            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text(store.autoRefreshLabel)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if let latestAvailableVersion = store.latestAvailableVersion {
                    Text("新版本 \(latestAvailableVersion)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.15, green: 0.59, blue: 0.42))
                }
                Text(AppMetadata.versionLabel)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.visibleProfiles.isEmpty {
                        Text(store.showUsableOnly ? "当前没有可直接使用的账号。" : "还没有保存任何账号档案。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        if !store.prioritizedProfiles.isEmpty {
                            SectionLabel(text: "优先使用")
                            ForEach(store.prioritizedProfiles) { profile in
                                ProfileCard(
                                    profile: profile,
                                    recommended: store.recommendedProfile?.profileName == profile.profileName,
                                    onSwitch: { store.switchTo(profile) },
                                    onRepair: { store.repair(profile) },
                                    onRename: { store.rename(profile) },
                                    onDelete: { store.delete(profile) }
                                )
                            }
                        }

                        if !store.overflowProfiles.isEmpty {
                            SectionLabel(text: "已满 / 暂不可用")
                            ForEach(store.overflowProfiles) { profile in
                                ProfileCard(
                                    profile: profile,
                                    recommended: store.recommendedProfile?.profileName == profile.profileName,
                                    onSwitch: { store.switchTo(profile) },
                                    onRepair: { store.repair(profile) },
                                    onRename: { store.rename(profile) },
                                    onDelete: { store.delete(profile) }
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(width: 460, height: 640)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            store.refresh(silent: true)
        }
    }
}

@main
struct CodexMenuBarApp: App {
    @StateObject private var store = ProfileStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.menuBarColor)
                    .frame(width: 8, height: 8)
                Text(store.menuBarTitle)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 2)
        }
        .menuBarExtraStyle(.window)
    }
}
