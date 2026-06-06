import AppKit
import Foundation
import Security
import SwiftUI

@main
struct NewAPIAccountMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MonitorViewModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarSettingsPanel(appDelegate: appDelegate)
                .environmentObject(viewModel)
                .frame(width: 430)
                .padding(16)
                .task {
                    await viewModel.refresh()
                }
        } label: {
            Text(viewModel.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPanel()
                .environmentObject(viewModel)
                .frame(width: 460)
                .padding(20)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let viewModel = MonitorViewModel.shared
    private var panel: NSPanel?
    @Published private(set) var isPositioningMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showDesktopWidget()
        Task { await viewModel.refresh() }
    }

    private func showDesktopWidget() {
        let config = WidgetWindowConfig.load()
        let panel = DesktopWidgetPanel(config: config)
        panel.contentView = NSHostingView(rootView: DesktopWidget().environmentObject(viewModel))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func setPositioningMode(_ enabled: Bool) {
        isPositioningMode = enabled
        guard let panel = panel as? DesktopWidgetPanel else { return }
        panel.setPositioningMode(enabled)
    }

    func togglePositioningMode() {
        setPositioningMode(!isPositioningMode)
    }
}

struct WidgetWindowConfig {
    let x: CGFloat
    let yFromTop: CGFloat
    let width: CGFloat
    let height: CGFloat

    static func load() -> WidgetWindowConfig {
        let env = EnvFile.load()
        return WidgetWindowConfig(
            x: CGFloat(Double(env["HYPERAPI_WIDGET_X"] ?? "") ?? 38),
            yFromTop: CGFloat(Double(env["HYPERAPI_WIDGET_Y"] ?? "") ?? 240),
            width: CGFloat(Double(env["HYPERAPI_WIDGET_WIDTH"] ?? "") ?? 344),
            height: CGFloat(Double(env["HYPERAPI_WIDGET_HEIGHT"] ?? "") ?? 430)
        )
    }
}

final class DesktopWidgetPanel: NSPanel {
    init(config: WidgetWindowConfig) {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let origin = NSPoint(
            x: screenFrame.minX + config.x,
            y: screenFrame.maxY - config.yFromTop - config.height
        )
        let rect = NSRect(origin: origin, size: NSSize(width: config.width, height: config.height))

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setPositioningMode(_ enabled: Bool) {
        ignoresMouseEvents = !enabled
        level = enabled ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        hasShadow = false
        if enabled {
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }
}

@MainActor
final class MonitorViewModel: ObservableObject {
    static let shared = MonitorViewModel()

    @Published private(set) var snapshot: AccountSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var consumptionEvents: [ConsumptionEvent] = []
    @Published var isConsumptionEffectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isConsumptionEffectEnabled, forKey: "isConsumptionEffectEnabled")
        }
    }
    @Published var refreshInterval: RefreshInterval = .thirtySeconds {
        didSet { scheduleTimer() }
    }
    @Published var menuBarSelection: String {
        didSet {
            UserDefaults.standard.set(menuBarSelection, forKey: "menuBarSelection")
        }
    }
    @Published var widgetSubscriptionLimit: Int {
        didSet {
            let clamped = min(max(widgetSubscriptionLimit, 1), 12)
            if widgetSubscriptionLimit != clamped {
                widgetSubscriptionLimit = clamped
                return
            }
            UserDefaults.standard.set(widgetSubscriptionLimit, forKey: "widgetSubscriptionLimit")
        }
    }
    @Published private var hiddenSubscriptionIDList: [Int] {
        didSet {
            UserDefaults.standard.set(hiddenSubscriptionIDList, forKey: "hiddenSubscriptionIDs")
        }
    }

    private let client = HyperAPIClient()
    private var timerTask: Task<Void, Never>?

    var menuBarTitle: String {
        if isLoading { return "AI ..." }
        if lastError != nil { return "AI !" }
        guard let snapshot else { return "AI 余额" }

        switch MenuBarSelection(rawValue: menuBarSelection) {
        case .currentBalance:
            return snapshot.currentBalance
        case .historicalUsage:
            return snapshot.historicalUsage
        case .requestCount:
            return snapshot.requestCountText
        case .subscriptionAmount(let id):
            return snapshot.validSubscriptions.first { $0.id == id }?.remainingText ?? snapshot.currentBalance
        case .subscriptionPercent(let id):
            return snapshot.validSubscriptions.first { $0.id == id }?.remainingPercentText ?? snapshot.currentBalance
        case .none:
            return snapshot.currentBalance
        }
    }

    var validSubscriptions: [SubscriptionDisplay] {
        snapshot?.validSubscriptions ?? SubscriptionDisplay.placeholders
    }

    var displayedSubscriptions: [SubscriptionDisplay] {
        Array(
            validSubscriptions
                .filter { !hiddenSubscriptionIDs.contains($0.id) }
                .prefix(widgetSubscriptionLimit)
        )
    }

    var hiddenSubscriptionIDs: Set<Int> {
        get { Set(hiddenSubscriptionIDList) }
        set { hiddenSubscriptionIDList = Array(newValue).sorted() }
    }

    var maxSubscriptionLimit: Int {
        max(1, min(12, validSubscriptions.count))
    }

    init() {
        let defaults = UserDefaults.standard
        menuBarSelection = defaults.string(forKey: "menuBarSelection") ?? MenuBarSelection.currentBalance.rawValue
        let savedLimit = defaults.integer(forKey: "widgetSubscriptionLimit")
        widgetSubscriptionLimit = savedLimit == 0 ? 3 : min(max(savedLimit, 1), 12)
        hiddenSubscriptionIDList = defaults.array(forKey: "hiddenSubscriptionIDs") as? [Int] ?? []
        isConsumptionEffectEnabled = defaults.object(forKey: "isConsumptionEffectEnabled") as? Bool ?? true
        scheduleTimer()
    }

    deinit {
        timerTask?.cancel()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil

        do {
            let newSnapshot = try await client.fetchSnapshot()
            if isConsumptionEffectEnabled, let oldSnapshot = snapshot {
                registerConsumptionEvents(from: oldSnapshot, to: newSnapshot)
            }
            snapshot = newSnapshot
        } catch {
            lastError = error.localizedDescription
        }

        isLoading = false
    }

    func scheduleTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(refreshInterval.seconds))
                await self.refresh()
            }
        }
    }

    func setSubscription(_ subscription: SubscriptionDisplay, isVisible: Bool) {
        var ids = hiddenSubscriptionIDs
        if isVisible {
            ids.remove(subscription.id)
        } else {
            ids.insert(subscription.id)
        }
        hiddenSubscriptionIDs = ids
    }

    func triggerTestConsumptionEffect() {
        consumptionEvents.append(
            ConsumptionEvent(
                kind: .balance,
                text: "-3$",
                horizontalRatio: 0.50
            )
        )

        guard let event = consumptionEvents.last else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            await MainActor.run {
                self?.consumptionEvents.removeAll { $0.id == event.id }
            }
        }
    }

    func triggerTestSubscriptionConsumptionEffect() {
        let targetID = displayedSubscriptions.first?.id ?? 128
        consumptionEvents.append(
            ConsumptionEvent(
                kind: .subscription(targetID),
                text: "-3$",
                horizontalRatio: 0.50
            )
        )

        guard let event = consumptionEvents.last else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            await MainActor.run {
                self?.consumptionEvents.removeAll { $0.id == event.id }
            }
        }
    }

    private func registerConsumptionEvents(from oldSnapshot: AccountSnapshot, to newSnapshot: AccountSnapshot) {
        var events: [ConsumptionEvent] = []
        let balanceDelta = oldSnapshot.currentBalanceRaw - newSnapshot.currentBalanceRaw
        if balanceDelta > 0 {
            events.append(
                ConsumptionEvent(
                    kind: .balance,
                    text: "-\(MoneyFormatter.formatPlain(balanceDelta))",
                    horizontalRatio: 0.18
                )
            )
        }

        let oldByID = Dictionary(uniqueKeysWithValues: oldSnapshot.validSubscriptions.map { ($0.id, $0) })
        for (index, subscription) in newSnapshot.validSubscriptions.enumerated() {
            guard let old = oldByID[subscription.id] else { continue }
            let delta = old.remainingRaw - subscription.remainingRaw
            guard delta > 0 else { continue }
            events.append(
                ConsumptionEvent(
                    kind: .subscription(subscription.id),
                    text: "-\(MoneyFormatter.formatPlain(delta))",
                    horizontalRatio: min(0.84, 0.24 + Double(index % 3) * 0.25)
                )
            )
        }

        for event in events {
            consumptionEvents.append(event)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1800))
                await MainActor.run {
                    self?.consumptionEvents.removeAll { $0.id == event.id }
                }
            }
        }
    }
}

struct ConsumptionEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case balance
        case subscription(Int)
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let horizontalRatio: Double
}

enum MenuBarSelection: RawRepresentable, Equatable {
    case currentBalance
    case historicalUsage
    case requestCount
    case subscriptionAmount(Int)
    case subscriptionPercent(Int)

    init?(rawValue: String) {
        switch rawValue {
        case "currentBalance":
            self = .currentBalance
        case "historicalUsage":
            self = .historicalUsage
        case "requestCount":
            self = .requestCount
        default:
            if rawValue.hasPrefix("subscriptionAmount."),
               let id = Int(rawValue.replacingOccurrences(of: "subscriptionAmount.", with: "")) {
                self = .subscriptionAmount(id)
            } else if rawValue.hasPrefix("subscriptionPercent."),
                      let id = Int(rawValue.replacingOccurrences(of: "subscriptionPercent.", with: "")) {
                self = .subscriptionPercent(id)
            } else {
                return nil
            }
        }
    }

    var rawValue: String {
        switch self {
        case .currentBalance:
            return "currentBalance"
        case .historicalUsage:
            return "historicalUsage"
        case .requestCount:
            return "requestCount"
        case .subscriptionAmount(let id):
            return "subscriptionAmount.\(id)"
        case .subscriptionPercent(let id):
            return "subscriptionPercent.\(id)"
        }
    }
}

enum RefreshInterval: String, CaseIterable, Identifiable {
    case tenSeconds = "10秒"
    case thirtySeconds = "30秒"
    case oneMinute = "1分钟"
    case fiveMinutes = "5分钟"

    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .tenSeconds: return 10
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        }
    }
}

struct MonitorPanel: View {
    let appDelegate: AppDelegate
    @EnvironmentObject private var viewModel: MonitorViewModel

    var body: some View {
        ZStack {
            WallpaperBackdrop()

            GlassShell {
                VStack(spacing: 22) {
                    MetricsGrid(snapshot: viewModel.snapshot)
                    SubscriptionList(snapshot: viewModel.snapshot)

                    HStack(spacing: 12) {
                        RefreshControl()
                        Button {
                            appDelegate.togglePositioningMode()
                        } label: {
                            Label(
                                appDelegate.isPositioningMode ? "锁定位置" : "定位模式",
                                systemImage: appDelegate.isPositioningMode ? "lock.fill" : "move.3d"
                            )
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        LastUpdatedView(snapshot: viewModel.snapshot, error: viewModel.lastError)
                    }
                }
                .padding(20)
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
    }
}

struct MenuBarSettingsPanel: View {
    @ObservedObject var appDelegate: AppDelegate
    @EnvironmentObject private var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HyperAPI 余额监控")
                            .font(.headline)
                        Text(viewModel.snapshot?.updatedText ?? "等待刷新")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("消耗淡出特效", isOn: $viewModel.isConsumptionEffectEnabled)
                        .font(.subheadline.weight(.semibold))

                    HStack {
                        Text("刷新后检测到余额或订阅减少时，在对应位置显示红色数字并逐渐透明。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("测试余额") {
                            viewModel.triggerTestConsumptionEffect()
                        }
                        Button("测试订阅") {
                            viewModel.triggerTestSubscriptionConsumptionEffect()
                        }
                    }
                }

                Divider()

                Picker("菜单栏显示", selection: $viewModel.menuBarSelection) {
                    Text("当前余额").tag(MenuBarSelection.currentBalance.rawValue)
                    Text("历史消耗").tag(MenuBarSelection.historicalUsage.rawValue)
                    Text("请求次数").tag(MenuBarSelection.requestCount.rawValue)

                    if !viewModel.validSubscriptions.isEmpty {
                        Divider()
                        ForEach(viewModel.validSubscriptions) { subscription in
                            Text("\(subscription.shortTitleLine) 剩余额度")
                                .tag(MenuBarSelection.subscriptionAmount(subscription.id).rawValue)
                            Text("\(subscription.shortTitleLine) 剩余百分比")
                                .tag(MenuBarSelection.subscriptionPercent(subscription.id).rawValue)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("悬浮窗订阅数量")
                        Spacer()
                        Stepper(
                            "\(viewModel.widgetSubscriptionLimit)",
                            value: $viewModel.widgetSubscriptionLimit,
                            in: 1...max(viewModel.maxSubscriptionLimit, 1)
                        )
                        .frame(width: 108)
                    }

                    Picker("刷新频率", selection: $viewModel.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.rawValue).tag(interval)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !viewModel.validSubscriptions.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 9) {
                        Text("悬浮窗订阅")
                            .font(.subheadline.weight(.semibold))

                        ForEach(viewModel.validSubscriptions) { subscription in
                            Toggle(
                                subscription.shortTitleLine,
                                isOn: Binding(
                                    get: { !viewModel.hiddenSubscriptionIDs.contains(subscription.id) },
                                    set: { viewModel.setSubscription(subscription, isVisible: $0) }
                                )
                            )
                        }
                    }
                }

                Divider()

                Button {
                    appDelegate.togglePositioningMode()
                } label: {
                    Label(
                        appDelegate.isPositioningMode ? "锁定悬浮窗位置" : "进入定位模式",
                        systemImage: appDelegate.isPositioningMode ? "lock.fill" : "move.3d"
                    )
                }

                if let error = viewModel.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxHeight: 560)
    }
}

struct DesktopWidget: View {
    @EnvironmentObject private var viewModel: MonitorViewModel

    var body: some View {
        ZStack {
            DesktopGlassShell {
                VStack(spacing: 12) {
                    CompactMetricsGrid(snapshot: viewModel.snapshot)
                    CompactSubscriptionList()

                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isLoading ? "arrow.triangle.2.circlepath" : "sparkle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.38))

                        Text(viewModel.snapshot?.updatedText ?? "等待刷新")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.38))

                        Spacer()

                        Text(viewModel.refreshInterval.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    .padding(.horizontal, 6)
                }
                .padding(16)
            }

            ConsumptionEffectLayer(events: viewModel.consumptionEvents)
        }
        .frame(minWidth: 300, minHeight: 360)
        .preferredColorScheme(.dark)
    }
}

struct ConsumptionEffectLayer: View {
    let events: [ConsumptionEvent]
    @EnvironmentObject private var viewModel: MonitorViewModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(events) { event in
                    FallingConsumptionText(event: event)
                        .position(position(for: event, in: proxy.size))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func position(for event: ConsumptionEvent, in size: CGSize) -> CGPoint {
        switch event.kind {
        case .balance:
            return CGPoint(x: size.width * 0.19, y: 78)
        case .subscription(let id):
            let rows = viewModel.displayedSubscriptions
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                return CGPoint(x: size.width * 0.50, y: 190)
            }
            let y = 148 + CGFloat(index) * 93
            return CGPoint(x: size.width * 0.79, y: y)
        }
    }
}

struct FallingConsumptionText: View {
    let event: ConsumptionEvent
    @State private var faded = false

    var body: some View {
        Text(event.text)
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.red.opacity(faded ? 0 : 0.96))
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            .scaleEffect(faded ? 0.98 : 1)
            .animation(.easeOut(duration: 1.8), value: faded)
            .onAppear {
                faded = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    faded = true
                }
            }
    }
}

struct CompactMetricsGrid: View {
    let snapshot: AccountSnapshot?

    private var metrics: [MetricItem] {
        [
            MetricItem(title: "当前余额", value: snapshot?.currentBalance ?? "--"),
            MetricItem(title: "历史消耗", value: snapshot?.historicalUsage ?? "--"),
            MetricItem(title: "请求次数", value: snapshot?.requestCountText ?? "--")
        ]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 9) {
                    Text(metric.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)

                    Text(metric.value)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.58)
                        .lineLimit(1)

                    Rectangle()
                        .fill(.white.opacity(0.30))
                        .frame(height: 1)
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                .background(GlassCardBackground(cornerRadius: 16, castsShadow: false))
            }
        }
    }
}

struct CompactSubscriptionList: View {
    @EnvironmentObject private var viewModel: MonitorViewModel

    private var rows: [SubscriptionDisplay] {
        viewModel.displayedSubscriptions
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows) { item in
                CompactSubscriptionCard(item: item)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.35), value: rows.map(\.id))
    }
}

struct CompactSubscriptionCard: View {
    let item: SubscriptionDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.shortTitleLine)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 8)

                Text(item.daysLine)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
            }

            Text(item.remainingLine)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)

            ProgressGlassBar(progress: item.remainingRatio)
                .frame(height: 12)

            if let resetText = item.resetLine {
                Text(resetText)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: item.resetLine == nil ? 76 : 93)
        .background(GlassCardBackground(cornerRadius: 17, castsShadow: false))
    }
}

struct DesktopGlassShell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.42, green: 0.88, blue: 1).opacity(0.24),
                                    Color(red: 0.12, green: 0.22, blue: 0.32).opacity(0.18),
                                    .black.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.60), .white.opacity(0.12), .white.opacity(0.46)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .padding(2)
    }
}

struct SettingsPanel: View {
    @EnvironmentObject private var viewModel: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HyperAPI 余额监控")
                .font(.title3.weight(.semibold))

            Text("Token 从 macOS Keychain 读取。若需要重新授权，请在终端运行 scripts/setup-hyperapi-token.sh。")
                .foregroundStyle(.secondary)

            Picker("刷新频率", selection: $viewModel.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .pickerStyle(.segmented)

            Button("立即刷新") {
                Task { await viewModel.refresh() }
            }
        }
    }
}

struct MetricsGrid: View {
    let snapshot: AccountSnapshot?

    private var metrics: [MetricItem] {
        [
            MetricItem(title: "当前余额", value: snapshot?.currentBalance ?? "--"),
            MetricItem(title: "历史消耗", value: snapshot?.historicalUsage ?? "--"),
            MetricItem(title: "请求次数", value: snapshot?.requestCountText ?? "--")
        ]
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(metrics) { metric in
                MetricCard(metric: metric)
            }
        }
    }
}

struct MetricItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct MetricCard: View {
    let metric: MetricItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(metric.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))

            Text(metric.value)
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .foregroundStyle(.white)

            Rectangle()
                .fill(.white.opacity(0.34))
                .frame(height: 1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 134, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 18))
    }
}

struct SubscriptionList: View {
    let snapshot: AccountSnapshot?

    private var rows: [SubscriptionDisplay] {
        snapshot?.validSubscriptions ?? SubscriptionDisplay.placeholders
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows) { item in
                SubscriptionCard(item: item)
            }
        }
    }
}

struct SubscriptionCard: View {
    let item: SubscriptionDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.titleLine)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(item.daysLine)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.72))
            }

            HStack {
                Text(item.remainingLine)
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.74))
                Spacer()
            }

            ProgressGlassBar(progress: item.remainingRatio)

            if let resetText = item.resetLine {
                Text(resetText)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: item.resetLine == nil ? 122 : 146)
        .background(GlassCardBackground(cornerRadius: 18))
    }
}

struct ProgressGlassBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(8, proxy.size.width * min(max(progress, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.43, blue: 1.0),
                                Color(red: 0.42, green: 0.37, blue: 1.0),
                                Color(red: 0.88, green: 0.28, blue: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width)
                    .shadow(color: Color(red: 0.48, green: 0.38, blue: 1).opacity(0.42), radius: 7, x: 0, y: 0)
            }
        }
        .frame(height: 18)
    }
}

struct RefreshControl: View {
    @EnvironmentObject private var viewModel: MonitorViewModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewModel.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.rawValue).tag(interval)
                }
            }
            .labelsHidden()
            .frame(width: 128)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct LastUpdatedView: View {
    let snapshot: AccountSnapshot?
    let error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let error {
                Text(error)
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.82))
            }

            Text(snapshot?.updatedText ?? "等待刷新")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
        }
    }
}

struct GlassShell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.16),
                                    .white.opacity(0.05),
                                    .black.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.14), .white.opacity(0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.1
                    )
            )
            .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 18)
    }
}

struct GlassCardBackground: View {
    let cornerRadius: CGFloat
    var castsShadow = true

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(0.08))
            .background(
                VisualEffectView(material: .popover, blendingMode: .withinWindow)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: .black.opacity(castsShadow ? 0.20 : 0), radius: castsShadow ? 12 : 0, x: 0, y: castsShadow ? 8 : 0)
    }
}

struct WallpaperBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.08, blue: 0.16),
                    Color(red: 0.08, green: 0.14, blue: 0.24),
                    Color(red: 0.01, green: 0.03, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.blue.opacity(0.24))
                .frame(width: 360)
                .blur(radius: 82)
                .offset(x: -150, y: -240)

            Circle()
                .fill(.purple.opacity(0.18))
                .frame(width: 300)
                .blur(radius: 90)
                .offset(x: 170, y: 210)

            LinearGradient(
                colors: [.clear, .white.opacity(0.10), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .rotationEffect(.degrees(-22))
            .offset(y: -110)
            .blur(radius: 16)
        }
        .ignoresSafeArea()
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

struct AccountSnapshot {
    let currentBalance: String
    let currentBalanceRaw: Int64
    let historicalUsage: String
    let historicalUsageRaw: Int64
    let requestCountText: String
    let validSubscriptions: [SubscriptionDisplay]
    let updatedAt: Date

    var updatedText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return "更新于 " + formatter.string(from: updatedAt)
    }
}

struct SubscriptionDisplay: Identifiable {
    let id: Int
    let titleLine: String
    let daysLine: String
    let remainingLine: String
    let remainingText: String
    let remainingPercentText: String
    let remainingRaw: Int64
    let resetLine: String?
    let remainingRatio: Double

    var shortTitleLine: String {
        titleLine
            .replacingOccurrences(of: "月卡套餐 ", with: "月卡套餐")
            .replacingOccurrences(of: " · 订阅 #", with: " #")
            .replacingOccurrences(of: "每日$300 月卡", with: "每日 $300")
    }

    static let placeholders = [
        SubscriptionDisplay(
            id: 128,
            titleLine: "月卡套餐 Plus · 订阅 #128",
            daysLine: "剩余 27 天",
            remainingLine: "剩余 $480.00 · 100%",
            remainingText: "$480.00",
            remainingPercentText: "100%",
            remainingRaw: 240_000_000,
            resetLine: nil,
            remainingRatio: 1
        ),
        SubscriptionDisplay(
            id: 109,
            titleLine: "月卡套餐 Plus · 订阅 #109",
            daysLine: "剩余 23 天",
            remainingLine: "剩余 $281.12 · 59%",
            remainingText: "$281.12",
            remainingPercentText: "59%",
            remainingRaw: 140_560_000,
            resetLine: nil,
            remainingRatio: 0.59
        ),
        SubscriptionDisplay(
            id: 97,
            titleLine: "每日$300 月卡 · 订阅 #97",
            daysLine: "剩余 22 天",
            remainingLine: "剩余 $298.76 · 99.6%",
            remainingText: "$298.76",
            remainingPercentText: "99.6%",
            remainingRaw: 149_380_000,
            resetLine: "下一次重置: 2026/6/8 00:00:00",
            remainingRatio: 0.996
        )
    ]
}

actor HyperAPIClient {
    private let config: AppConfig
    private let session: URLSession

    init(config: AppConfig = .load(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func fetchSnapshot() async throws -> AccountSnapshot {
        let token = try Keychain.readPassword(service: config.keychainService, account: config.keychainAccount)
        let selfResponse: APIResponse<UserData> = try await get("/api/user/self", token: token)
        let subsResponse: APIResponse<SubscriptionsData> = try await get("/api/subscription/self", token: token)
        let plansResponse: APIResponse<[PlanWrapper]> = try await get("/api/subscription/plans", token: token)

        guard let user = selfResponse.data else {
            throw MonitorError.invalidResponse(selfResponse.message ?? "用户信息为空")
        }
        guard let subscriptionsData = subsResponse.data else {
            throw MonitorError.invalidResponse(subsResponse.message ?? "订阅信息为空")
        }
        guard let planWrappers = plansResponse.data else {
            throw MonitorError.invalidResponse(plansResponse.message ?? "套餐信息为空")
        }

        let planTitles = Dictionary(uniqueKeysWithValues: planWrappers.compactMap { wrapper -> (Int, String)? in
            guard let plan = wrapper.plan else { return nil }
            return (plan.id, plan.title)
        })

        let validSubscriptions = subscriptionsData.subscriptions
            .compactMap(\.subscription)
            .filter { subscription in
                subscription.status == "active"
                    && subscription.endTime > Int64(Date().timeIntervalSince1970)
                    && subscription.amountUsed < subscription.amountTotal
            }
            .sorted { $0.id > $1.id }
            .map { subscription in
                makeDisplay(subscription: subscription, title: planTitles[subscription.planID])
            }

        return AccountSnapshot(
            currentBalance: MoneyFormatter.format(user.quota),
            currentBalanceRaw: user.quota,
            historicalUsage: MoneyFormatter.format(user.usedQuota),
            historicalUsageRaw: user.usedQuota,
            requestCountText: "\(user.requestCount)",
            validSubscriptions: validSubscriptions,
            updatedAt: Date()
        )
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> APIResponse<T> {
        let url = config.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        request.setValue(token, forHTTPHeaderField: "authorization")
        request.setValue(config.userID, forHTTPHeaderField: "new-api-user")
        request.setValue(config.baseURL.appendingPathComponent("console/topup").absoluteString, forHTTPHeaderField: "referer")

        let (data, response) = try await dataWithRetry(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MonitorError.invalidResponse("接口请求失败")
        }

        let decoded = try JSONDecoder.hyperapi.decode(APIResponse<T>.self, from: data)
        if decoded.success == false {
            throw MonitorError.invalidResponse(decoded.message ?? "接口返回失败")
        }
        return decoded
    }

    private func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            try await Task.sleep(for: .milliseconds(700))
            return try await session.data(for: request)
        }
    }

    private func makeDisplay(subscription: Subscription, title: String?) -> SubscriptionDisplay {
        let remaining = max(0, subscription.amountTotal - subscription.amountUsed)
        let remainingRatio = subscription.amountTotal > 0 ? Double(remaining) / Double(subscription.amountTotal) : 0
        let remainingPercent = PercentFormatter.format(remainingRatio)
        let remainingText = MoneyFormatter.format(remaining)
        let endDate = Date(timeIntervalSince1970: TimeInterval(subscription.endTime))
        let days = max(0, Int(ceil(endDate.timeIntervalSinceNow / 86_400)))

        return SubscriptionDisplay(
            id: subscription.id,
            titleLine: title.map { "\($0) · 订阅 #\(subscription.id)" } ?? "订阅 #\(subscription.id)",
            daysLine: "剩余 \(days) 天",
            remainingLine: "剩余 \(remainingText) · \(remainingPercent)",
            remainingText: remainingText,
            remainingPercentText: remainingPercent,
            remainingRaw: remaining,
            resetLine: subscription.nextResetTime > 0 ? "下一次重置: \(DateFormatter.hyperapiFull.string(from: Date(timeIntervalSince1970: TimeInterval(subscription.nextResetTime))))" : nil,
            remainingRatio: remainingRatio
        )
    }
}

struct AppConfig {
    let baseURL: URL
    let userID: String
    let keychainService: String

    var keychainAccount: String {
        "\(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))):\(userID)"
    }

    static func load() -> AppConfig {
        let env = EnvFile.load()
        let baseURLString = env["HYPERAPI_BASE_URL"] ?? "https://hyperapi.cc"
        let userID = env["HYPERAPI_USER_ID"] ?? ""
        let keychainService = env["HYPERAPI_KEYCHAIN_SERVICE"] ?? "newapi-account-scraper.hyperapi"

        return AppConfig(
            baseURL: URL(string: baseURLString) ?? URL(string: "https://hyperapi.cc")!,
            userID: userID,
            keychainService: keychainService
        )
    }
}

enum EnvFile {
    static func load(path: String = ".env") -> [String: String] {
        guard let envURL = locate(path: path),
              let text = try? String(contentsOf: envURL, encoding: .utf8) else {
            return [:]
        }
        var values: [String: String] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }

        return values
    }

    private static func locate(path: String) -> URL? {
        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: path)
        if directURL.isFileURL, fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let currentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(path)
        if fileManager.fileExists(atPath: currentURL.path) {
            return currentURL
        }

        var roots: [URL] = []
        if let executableURL = Bundle.main.executableURL {
            roots.append(executableURL.deletingLastPathComponent())
        }
        roots.append(Bundle.main.bundleURL)

        for root in roots {
            var cursor = root
            for _ in 0..<8 {
                let candidate = cursor.appendingPathComponent(path)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let next = cursor.deletingLastPathComponent()
                if next.path == cursor.path { break }
                cursor = next
            }
        }

        return nil
    }
}

enum Keychain {
    static func readPassword(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw MonitorError.missingToken
        }
        return password
    }
}

struct APIResponse<T: Decodable>: Decodable {
    let success: Bool?
    let message: String?
    let data: T?
}

struct UserData: Decodable {
    let quota: Int64
    let usedQuota: Int64
    let requestCount: Int

    enum CodingKeys: String, CodingKey {
        case quota
        case usedQuota = "used_quota"
        case requestCount = "request_count"
    }
}

struct SubscriptionsData: Decodable {
    let subscriptions: [SubscriptionWrapper]
}

struct SubscriptionWrapper: Decodable {
    let subscription: Subscription?
}

struct Subscription: Decodable {
    let id: Int
    let planID: Int
    let amountTotal: Int64
    let amountUsed: Int64
    let endTime: Int64
    let nextResetTime: Int64
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case planID = "plan_id"
        case amountTotal = "amount_total"
        case amountUsed = "amount_used"
        case endTime = "end_time"
        case nextResetTime = "next_reset_time"
        case status
    }
}

struct PlanWrapper: Decodable {
    let plan: Plan?
}

struct Plan: Decodable {
    let id: Int
    let title: String
}

enum MoneyFormatter {
    static func format(_ amount: Int64) -> String {
        let cents = cents(from: amount)
        return String(format: "$%lld.%02lld", cents / 100, cents % 100)
    }

    static func formatPlain(_ amount: Int64) -> String {
        let cents = cents(from: amount)
        if cents % 100 == 0 {
            return "\(cents / 100)$"
        }
        return String(format: "%lld.%02lld$", cents / 100, cents % 100)
    }

    private static func cents(from amount: Int64) -> Int {
        var cents = Int((Double(amount) / 5_000.0).rounded())
        if amount > 0 && cents == 0 {
            cents = 1
        }
        return cents
    }
}

enum PercentFormatter {
    static func format(_ ratio: Double) -> String {
        let value = ratio * 100
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(value.rounded()))%"
        }
        return String(format: "%.1f%%", value)
    }
}

enum MonitorError: LocalizedError {
    case missingToken
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Keychain 中没有 token，请先运行 setup 脚本"
        case .invalidResponse(let message):
            return message
        }
    }
}

extension JSONDecoder {
    static var hyperapi: JSONDecoder {
        JSONDecoder()
    }
}

extension DateFormatter {
    static let hyperapiFull: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy/M/d HH:mm:ss"
        return formatter
    }()
}
