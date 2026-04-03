import AppKit
import Combine
import Foundation
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
    static let usageURL = "https://chatgpt.com/codex/settings/usage"
    static let billingURL = "https://platform.openai.com/settings/organization/billing/overview"
    static let apiUsageURL = "https://platform.openai.com/usage"
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
        usage?.planDisplay ?? usage?.planType ?? "未知套餐"
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

@MainActor
private final class ProfileStore: ObservableObject {
    private static let autoRefreshInterval: TimeInterval = 180
    private static let lastQuotaAlertKey = "CodexSwitcher.lastQuotaAlertKey"
    private static let showUsableOnlyKey = "CodexSwitcher.showUsableOnly"
    private static let sortModeKey = "CodexSwitcher.sortMode"
    private static let accountWatchPollInterval: UInt64 = 2_000_000_000

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

    private var autoRefreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshMode: RefreshMode?
    private var pendingRefreshSilent = true
    private var accountWatchTask: Task<Void, Never>?
    private var watchedIdentityKey: String?
    private let notificationCenter = UNUserNotificationCenter.current()

    init() {
        configureNotifications()
        startAutoRefresh()
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
                    statusMessage = autoSavedMessage
                } else if !silent {
                    statusMessage = nil
                }
            } catch {
                statusMessage = error.localizedDescription
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
                statusMessage = autoSavedMessage.isEmpty
                    ? "连续添加已开启。现在去 Codex 登录下一个账号，我会自动保存。"
                    : autoSavedMessage
                postNotification(
                    title: "连续添加已开启",
                    body: "当前基准账号：\(baselineName)。你继续登录新账号时，我会自动加入切换器。"
                )
                startAccountWatchLoop()
            } catch {
                statusMessage = error.localizedDescription
                PromptCenter.info(title: "无法开启连续添加", message: error.localizedDescription)
            }
        }
    }

    func quickSwitch() {
        guard let recommendedProfile else {
            statusMessage = "暂时没有可直接接力的可用账号。"
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
            statusMessage = "连续添加已停止。"
        }
    }

    func switchTo(_ profile: ProfilePayload) {
        statusMessage = "正在切换到 \(profile.profileName)..."
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

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else {
            return
        }
        NSWorkspace.shared.open(url)
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
                    statusMessage = autoSavedMessage.isEmpty
                        ? "已识别并保存 \(displayName)。继续登录下一个账号也会自动保存。"
                        : autoSavedMessage
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
                statusMessage = output.isEmpty ? "已完成。" : output
                refresh(silent: true)
                if showSuccessAlert {
                    PromptCenter.info(title: successTitle, message: output.isEmpty ? "已完成。" : output)
                }
            } catch {
                statusMessage = error.localizedDescription
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

            if let error = profile.usage?.error {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.22))
                    .lineLimit(1)
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
            return "未知"
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
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                    Button("打开 Codex 用量页") {
                        store.openUsagePage()
                    }

                    Button("打开账单") {
                        store.openBilling()
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
