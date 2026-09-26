import AppKit
import SwiftUI
import Combine
import Darwin
import ApplicationServices
import QuartzCore

struct MeterError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Quota: Identifiable {
    let id: String
    let title: String
    let used: Double?
    let minutes: Int?
    let reset: Double?

    var remaining: Double? { used.map { max(0, min(100, 100 - $0)) } }
    var resetText: String {
        guard let reset else { return "重置时间暂不可用" }
        let date = Date(timeIntervalSince1970: reset)
        if date <= Date() { return "等待服务端更新" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return "重置于 \(formatter.string(from: date))"
    }
}

func decodeQuotas(_ result: [String: Any]) -> [Quota] {
    let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
    let fallback = result["rateLimits"] as? [String: Any] ?? [:]
    let entries = buckets?.isEmpty == false ? buckets! : ["codex": fallback]
    return entries.keys.sorted().flatMap { key -> [Quota] in
        let bucket = entries[key] ?? [:]
        return ["primary", "secondary"].compactMap { slot in
            guard let window = bucket[slot] as? [String: Any] else { return nil }
            let minutes = window["windowDurationMins"] as? Int
            let label: String
            if minutes == 300 { label = "5 小时额度" }
            else if minutes == 10080 { label = "每周额度" }
            else if let minutes { label = minutes >= 1440 ? "\(minutes / 1440) 天额度" : "\(minutes) 分钟额度" }
            else { label = slot == "primary" ? "主要额度" : "次要额度" }
            let name = bucket["limitName"] as? String ?? key
            return Quota(
                id: key + slot,
                title: entries.count > 1 ? "\(name) · \(label)" : label,
                used: window["usedPercent"] as? Double,
                minutes: minutes,
                reset: window["resetsAt"] as? Double
            )
        }
    }
}

func resetCount(_ result: [String: Any]) -> Int? {
    guard let summary = result["rateLimitResetCredits"] as? [String: Any],
          let count = summary["availableCount"] as? Int, count >= 0 else { return nil }
    return count
}

func fetchQuotaData() throws -> [String: Any] {
    let candidates = [
        ProcessInfo.processInfo.environment["CODEX_BINARY"] ?? "",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]
    guard let binary = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw MeterError(message: "未找到 Codex。请先安装并登录 Codex 桌面端。")
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["app-server", "--listen", "stdio://"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
        "name": "codex_meter", "title": "Codex Meter", "version": "1.2.0"
    ]]])

    var buffer = Data()
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 200)
        if ready < 0 { throw MeterError(message: "连接中断，请重试。") }
        if ready == 0 { continue }
        let data = output.fileHandleForReading.availableData
        if data.isEmpty { throw MeterError(message: "Codex 连接已关闭，请确认已登录。") }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            if let error = object["error"] as? [String: Any] {
                throw MeterError(message: error["message"] as? String ?? "读取失败")
            }
            if id == 1 {
                try send(["method": "initialized"])
                try send(["id": 2, "method": "account/rateLimits/read"])
            } else if id == 2, let result = object["result"] as? [String: Any] {
                return result
            }
        }
    }
    throw MeterError(message: "连接超时。请检查网络，并确认 Codex 已登录。")
}

enum DockItem: String, CaseIterable, Identifiable {
    case fiveHour, weekly, resets
    var id: String { rawValue }
    var label: String {
        switch self { case .fiveHour: return "5 小时额度"; case .weekly: return "周额度"; case .resets: return "重置次数" }
    }
    var symbol: String {
        switch self { case .fiveHour: return "clock"; case .weekly: return "calendar"; case .resets: return "arrow.counterclockwise" }
    }
}

enum DockEdge: String, CaseIterable {
    case left, right, top, bottom
    var isHorizontal: Bool { self == .top || self == .bottom }
    var label: String {
        switch self { case .left: return "左侧"; case .right: return "右侧"; case .top: return "顶部"; case .bottom: return "底部" }
    }
}

final class MeterModel: ObservableObject {
    @Published var quotas: [Quota] = []
    @Published var resets: Int?
    @Published var loading = false
    @Published var error: String?
    @Published var updated: Date?
    @Published var pinned = false
    @Published var widget = false
    @Published var dock = UserDefaults.standard.bool(forKey: "dock")
    @Published var followVisibility = UserDefaults.standard.bool(forKey: "followVisibility")
    @Published var alwaysTop = UserDefaults.standard.bool(forKey: "alwaysTop")
    @Published var dockEdge = DockEdge(rawValue: UserDefaults.standard.string(forKey: "dockEdge") ?? "right") ?? .right
    @Published var dockFraction = UserDefaults.standard.object(forKey: "dockFraction") == nil ? 0.85 : UserDefaults.standard.double(forKey: "dockFraction")
    @Published var hiddenItems = Set(UserDefaults.standard.stringArray(forKey: "hiddenDockItems") ?? [])
    @Published var theme = UserDefaults.standard.string(forKey: "meterTheme") ?? "system"
    @Published var followStatus = ""
    var changed: (() -> Void)?
    var optionsChanged: (() -> Void)?

    var scheme: ColorScheme? { theme == "dark" ? .dark : theme == "light" ? .light : nil }
    var visibleItems: [DockItem] { DockItem.allCases.filter { !hiddenItems.contains($0.rawValue) } }

    func quota(for item: DockItem) -> Quota? {
        let duration = item == .fiveHour ? 300 : 10080
        let matches = quotas.filter { $0.minutes == duration }
        return matches.first { $0.id == "codexprimary" || $0.id == "codexsecondary" } ?? matches.first
    }

    func setVisible(_ item: DockItem, _ visible: Bool) {
        if visible { hiddenItems.remove(item.rawValue) } else { hiddenItems.insert(item.rawValue) }
        UserDefaults.standard.set(Array(hiddenItems), forKey: "hiddenDockItems")
        changed?()
    }

    func saveOptions() {
        UserDefaults.standard.set(dock, forKey: "dock")
        UserDefaults.standard.set(followVisibility, forKey: "followVisibility")
        UserDefaults.standard.set(alwaysTop, forKey: "alwaysTop")
        UserDefaults.standard.set(dockEdge.rawValue, forKey: "dockEdge")
        UserDefaults.standard.set(dockFraction, forKey: "dockFraction")
        optionsChanged?()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try fetchQuotaData() }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let data):
                    self.quotas = decodeQuotas(data)
                    self.resets = resetCount(data)
                    self.updated = Date()
                    self.error = self.quotas.isEmpty ? "此账户暂未提供订阅额度。" : nil
                case .failure(let error): self.error = error.localizedDescription
                }
                self.changed?()
            }
        }
    }
}

struct ItemSettings: View {
    @ObservedObject var model: MeterModel
    var body: some View {
        ForEach(DockItem.allCases) { item in
            Toggle(item.label, isOn: Binding(get: { !model.hiddenItems.contains(item.rawValue) }, set: { model.setVisible(item, $0) }))
        }
        Divider()
        Button("恢复全部项目") { DockItem.allCases.forEach { model.setVisible($0, true) } }
    }
}

struct ThemeSettings: View {
    @ObservedObject var model: MeterModel
    var body: some View {
        Picker("外观", selection: Binding(get: { model.theme }, set: {
            model.theme = $0
            UserDefaults.standard.set($0, forKey: "meterTheme")
            model.changed?()
        })) {
            Text("跟随系统").tag("system")
            Text("浅色").tag("light")
            Text("深色").tag("dark")
        }
    }
}

struct MeterView: View {
    @ObservedObject var model: MeterModel
    let compact: Bool
    let pin: () -> Void
    let widget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 20) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.system(size: 19))
                    .frame(width: 36, height: 36).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Meter").font(.system(size: 16, weight: .semibold))
                    Text(compact ? "桌面小组件" : "账户额度 · 剩余可用").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: pin) { Image(systemName: model.pinned ? "pin.fill" : "pin") }.buttonStyle(.plain)
            }
            if model.quotas.isEmpty && model.loading {
                HStack { ProgressView().controlSize(.small); Text("正在读取账户额度…").font(.callout) }.padding(.vertical, 20)
            }
            ForEach(model.quotas) { quota in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(quota.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text(quota.remaining.map { "\(Int($0.rounded()))" } ?? "—").font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("%").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule().fill(Color.primary.opacity(0.85)).frame(width: geometry.size.width * (quota.remaining ?? 0) / 100)
                        }
                    }.frame(height: 6)
                    Text(quota.resetText).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Circle().fill(model.error == nil ? Color.primary : .orange).frame(width: 5, height: 5)
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    Text(model.updated.map { "\(max(0, Int(context.date.timeIntervalSince($0)))) 秒前更新" } ?? "等待同步")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.disabled(model.loading)
                if !compact { Button(action: widget) { Image(systemName: "rectangle.on.rectangle") } }
                Menu {
                    Button(model.widget ? "隐藏桌面小组件" : "显示桌面小组件", action: widget)
                    Divider()
                    Menu("吸附栏显示项目") { ItemSettings(model: model) }
                    Menu("外观") { ThemeSettings(model: model) }
                    Toggle("吸附 GPT 窗口", isOn: Binding(get: { model.dock }, set: { model.dock = $0; model.saveOptions() }))
                    Toggle(model.dock ? "随 GPT 隐藏（吸附时自动）" : "跟随 GPT 显示 / 隐藏", isOn: Binding(
                        get: { model.dock || model.followVisibility }, set: { model.followVisibility = $0; model.saveOptions() }
                    )).disabled(model.dock)
                    Toggle("小组件始终置顶", isOn: Binding(get: { model.alwaysTop }, set: { model.alwaysTop = $0; model.saveOptions() }))
                    Divider()
                    Text("每 30 秒刷新 · 非官方工具")
                    Button("退出 Codex Meter") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.plain)
        }
        .padding(compact ? 18 : 22)
        .frame(width: compact ? 284 : 340)
    }
}

struct DockRail: View {
    @ObservedObject var model: MeterModel
    @Environment(\.colorScheme) private var scheme

    private var managementMenu: some View {
        Menu {
            Text(model.followStatus.isEmpty ? "窗口跟随" : model.followStatus)
            Text("停靠位置：\(model.dockEdge.label)")
            ItemSettings(model: model)
            Divider()
            Toggle("始终置顶", isOn: Binding(get: { model.alwaysTop }, set: { model.alwaysTop = $0; model.saveOptions() }))
            Text("随 GPT 隐藏（吸附时自动）")
            Menu("外观") { ThemeSettings(model: model) }
            Button("刷新额度") { model.refresh() }
        } label: {
            Image(systemName: model.error == nil ? "ellipsis" : "exclamationmark.circle")
                .font(.system(size: 7.5, weight: .medium)).frame(width: 17, height: 12)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary).help(model.error ?? "管理显示项目；拖动额度项可更换停靠边")
    }

    private func gauge(_ item: DockItem, quota: Quota?) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.13), lineWidth: 2)
            if item != .resets, let remaining = quota?.remaining {
                Circle().trim(from: 0, to: remaining / 100)
                    .stroke(Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: item.symbol).font(.system(size: 10)).foregroundStyle(.primary)
        }.frame(width: 22, height: 22)
    }

    @ViewBuilder
    private func itemView(_ item: DockItem, horizontal: Bool) -> some View {
        let quota = model.quota(for: item)
        let value = item == .resets ? model.resets.map { "\($0) 次" } ?? "—" : quota?.remaining.map { "\(Int($0.rounded()))%" } ?? "—"
        Group {
            if horizontal {
                HStack(spacing: 3) {
                    gauge(item, quota: quota)
                    Text(value).font(.system(size: 8, weight: .semibold, design: .rounded)).monospacedDigit()
                }.frame(width: 52, height: 38)
            } else {
                VStack(spacing: 3.5) {
                    gauge(item, quota: quota)
                    Text(value).font(.system(size: 8, weight: .semibold, design: .rounded)).monospacedDigit()
                }.frame(width: 38, height: 52)
            }
        }
        .help(item.label + " · " + (item == .resets ? "可用重置次数，仅展示" : quota?.resetText ?? "额度暂不可用"))
        .accessibilityLabel(item.label)
        .accessibilityElement(children: .combine)
        .contextMenu { Button("移除\(item.label)") { model.setVisible(item, false) } }
    }

    var body: some View {
        Group {
            if model.dockEdge.isHorizontal {
                HStack(spacing: 0) {
                    managementMenu.frame(width: 28, height: 38)
                    ForEach(model.visibleItems) { item in itemView(item, horizontal: true) }
                    if model.visibleItems.isEmpty { Image(systemName: "plus").font(.system(size: 8)).frame(width: 28, height: 38) }
                }
            } else {
                VStack(spacing: 0) {
                    managementMenu.frame(width: 38, height: 28)
                    ForEach(model.visibleItems) { item in itemView(item, horizontal: false) }
                    if model.visibleItems.isEmpty { Image(systemName: "plus").font(.system(size: 8)).frame(width: 38, height: 28) }
                }
            }
        }
        .background(scheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.075) : Color(red: 0.97, green: 0.97, blue: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct PanelContent: View {
    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject var model: MeterModel
    let compact: Bool
    let pin: () -> Void
    let widget: () -> Void

    var body: some View {
        Group {
            if compact && model.dock { DockRail(model: model) }
            else { MeterView(model: model, compact: compact, pin: pin, widget: widget) }
        }.environment(\.colorScheme, model.scheme ?? systemScheme)
    }
}

final class HoverView: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FloatingPanel: NSPanel {
    var dockDragEnabled: () -> Bool = { false }
    var dockEdge: () -> DockEdge = { .right }
    var dragBegan: () -> Void = {}
    var dragChanged: (CGSize) -> Void = { _ in }
    var dragEnded: (CGSize) -> Void = { _ in }
    var dragCancelled: () -> Void = {}
    private var start = CGPoint.zero
    private var eligible = false
    private var dragging = false
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            start = NSEvent.mouseLocation
            let point = event.locationInWindow
            let menu = dockEdge().isHorizontal ? point.x <= 30 : point.y >= frame.height - 30
            eligible = dockDragEnabled() && !menu
            dragging = false
            if eligible { dragBegan(); return }
            super.sendEvent(event)
        case .leftMouseDragged where eligible:
            let point = NSEvent.mouseLocation
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            if dragging || hypot(delta.width, delta.height) >= 3 {
                dragging = true
                dragChanged(delta)
            }
        case .leftMouseUp where eligible:
            let point = NSEvent.mouseLocation
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            dragging ? dragEnded(delta) : dragCancelled()
            eligible = false
            dragging = false
        case .keyDown where eligible && event.keyCode == 53:
            eligible = false
            dragging = false
            dragCancelled()
        default: super.sendEvent(event)
        }
    }
}

struct TargetWindow {
    let id: Int
    let bounds: CGRect
    let visible: Bool
}

private func parseWindow(_ row: [String: Any]) -> TargetWindow? {
    guard let id = row[kCGWindowNumber as String] as? Int,
          let dictionary = row[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
    return TargetWindow(id: id, bounds: bounds, visible: row[kCGWindowIsOnscreen as String] as? Bool ?? false)
}

func targetWindows(pid: pid_t) -> [TargetWindow] {
    let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    return rows.compactMap { row in
        guard (row[kCGWindowOwnerPID as String] as? Int) == Int(pid),
              (row[kCGWindowLayer as String] as? Int) == 0,
              let window = parseWindow(row), window.bounds.width > 150, window.bounds.height > 100 else { return nil }
        return window
    }
}

func targetWindow(id: Int) -> TargetWindow? {
    let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]] ?? []
    return rows.compactMap(parseWindow).first { $0.id == id }
}

func dockOrigin(edge: DockEdge, fraction: CGFloat, target: CGRect, widget: CGSize, screen: CGRect) -> CGPoint {
    let gap: CGFloat = 6
    let fraction = max(0, min(1, fraction))
    let centeredX = target.minX + target.width * fraction - widget.width / 2
    let centeredY = target.minY + target.height * fraction - widget.height / 2
    let raw: CGPoint
    switch edge {
    case .left:
        raw = CGPoint(x: target.minX - widget.width - gap >= screen.minX ? target.minX - widget.width - gap : target.minX + gap, y: centeredY)
    case .right:
        raw = CGPoint(x: target.maxX + widget.width + gap <= screen.maxX ? target.maxX + gap : target.maxX - widget.width - gap, y: centeredY)
    case .top:
        raw = CGPoint(x: centeredX, y: target.maxY + widget.height + gap <= screen.maxY ? target.maxY + gap : target.maxY - widget.height - gap)
    case .bottom:
        raw = CGPoint(x: centeredX, y: target.minY - widget.height - gap >= screen.minY ? target.minY - widget.height - gap : target.minY + gap)
    }
    return CGPoint(x: max(screen.minX, min(raw.x, screen.maxX - widget.width)), y: max(screen.minY, min(raw.y, screen.maxY - widget.height)))
}

func nearestDockEdge(point: CGPoint, target: CGRect) -> DockEdge {
    let distances: [(DockEdge, CGFloat)] = [
        (.left, abs(point.x - target.minX)), (.right, abs(point.x - target.maxX)),
        (.top, abs(point.y - target.maxY)), (.bottom, abs(point.y - target.minY))
    ]
    return distances
        .min { $0.1 < $1.1 }?.0 ?? .right
}

private func accessibilityCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.boostTracking()
        if notification as String == kAXFocusedWindowChangedNotification as String || notification as String == kAXWindowCreatedNotification as String {
            delegate.observeFocusedWindow()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MeterModel()
    var statusItem: NSStatusItem!
    var menuPanel: FloatingPanel!
    var widgetPanel: FloatingPanel!
    var refreshTimer: Timer?
    var trackingTimer: Timer?
    var hoverTimer: Timer?
    var clickOpen = false

    let trackingQueue = DispatchQueue(label: "local.codexmeter.tracking", qos: .userInteractive)
    var queryInFlight = false
    var generation = 0
    var cachedPID: pid_t?
    var trackedWindowID: Int?
    var lastTargetRect: CGRect?
    var lastBounds: CGRect?
    var nextQueryAt: CFTimeInterval = 0
    var fastUntil: CFTimeInterval = 0
    var wasTargetActive = false

    var draggingDock = false
    var dragStartOrigin = CGPoint.zero

    var axObserver: AXObserver?
    var axApplication: AXUIElement?
    var axWindow: AXUIElement?
    var axPID: pid_t?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex 额度")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggleMenu)
            let hover = HoverView(frame: button.bounds)
            hover.autoresizingMask = [.width, .height]
            hover.entered = { [weak self] in self?.showMenu(); self?.hoverTimer?.invalidate() }
            hover.exited = { [weak self] in self?.scheduleHideMenu() }
            button.addSubview(hover)
        }

        menuPanel = makePanel(compact: false)
        widgetPanel = makePanel(compact: true)
        widgetPanel.setFrameAutosaveName("CodexMeterWidget")
        if !widgetPanel.setFrameUsingName("CodexMeterWidget") { widgetPanel.setFrameOrigin(CGPoint(x: 60, y: 180)) }

        model.changed = { [weak self] in self?.updateUI() }
        model.optionsChanged = { [weak self] in
            guard let self else { return }
            if (self.model.dock || self.model.followVisibility) && !self.model.widget { self.toggleWidget() }
            self.updateUI()
            self.boostTracking()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.model.refresh() }
        trackingTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.trackingTick() }
        RunLoop.main.add(trackingTimer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didHideApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)

        model.refresh()
        if UserDefaults.standard.bool(forKey: "widgetVisible") { toggleWidget() }
        if CommandLine.arguments.contains("--show") { showMenu(); clickOpen = true }
    }

    func makePanel(compact: Bool) -> FloatingPanel {
        let panel = FloatingPanel(contentRect: CGRect(x: 0, y: 0, width: compact ? 284 : 340, height: 320), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if compact {
            panel.dockDragEnabled = { [weak self] in self?.model.dock == true }
            panel.dockEdge = { [weak self] in self?.model.dockEdge ?? .right }
            panel.dragBegan = { [weak self] in self?.dockDragBegan() }
            panel.dragChanged = { [weak self] in self?.dockDragChanged($0) }
            panel.dragEnded = { [weak self] in self?.dockDragEnded($0) }
            panel.dragCancelled = { [weak self] in self?.dockDragCancelled() }
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: PanelContent(
            model: model, compact: compact,
            pin: { [weak self] in self?.togglePin() },
            widget: { [weak self] in self?.toggleWidget() }
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        panel.contentView = effect
        return panel
    }

    func updateUI() {
        let remaining = model.quotas.compactMap(\.remaining).min()
        statusItem.button?.title = model.error != nil ? " —" : remaining.map { " \(Int($0))%" } ?? " …"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusItem.button?.toolTip = model.error ?? "Codex 剩余额度 · 悬停查看"
        resize(menuPanel, width: 340)
        if !draggingDock { resize(widgetPanel, width: model.dock ? 38 : 284) }
    }

    func resize(_ panel: NSPanel, width: CGFloat) {
        let rail = panel === widgetPanel && model.dock
        if let effect = panel.contentView as? NSVisualEffectView {
            effect.material = rail ? .contentBackground : .hudWindow
            effect.layer?.cornerRadius = rail ? 19 : 20
        }
        let length = CGFloat(28 + max(1, model.visibleItems.count) * 52)
        let resolvedWidth = rail ? (model.dockEdge.isHorizontal ? length : 38) : width
        let height = rail ? (model.dockEdge.isHorizontal ? 38 : length) : (panel.contentView?.fittingSize.height ?? 320)
        let top = panel.frame.maxY
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - height, width: resolvedWidth, height: height), display: true)
    }

    @objc func toggleMenu() {
        if menuPanel.isVisible && clickOpen && !model.pinned { hideMenu() }
        else { clickOpen = true; showMenu() }
    }

    func showMenu() {
        guard let button = statusItem.button, let window = button.window else { return }
        resize(menuPanel, width: 340)
        if !model.pinned || !menuPanel.isVisible {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            menuPanel.setFrameOrigin(CGPoint(x: max(screen.minX + 8, min(rect.midX - 170, screen.maxX - 348)), y: rect.minY - menuPanel.frame.height - 7))
        }
        menuPanel.orderFrontRegardless()
        if model.updated == nil || Date().timeIntervalSince(model.updated!) > 10 { model.refresh() }
    }

    func hideMenu() { guard !model.pinned else { return }; menuPanel.orderOut(nil); clickOpen = false }
    func scheduleHideMenu() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, !self.model.pinned, !self.clickOpen else { return }
            if !self.menuPanel.frame.insetBy(dx: -5, dy: -8).contains(NSEvent.mouseLocation) { self.hideMenu() }
        }
    }
    func togglePin() { model.pinned.toggle(); menuPanel.isMovableByWindowBackground = model.pinned; if model.pinned { showMenu() } }
    func toggleWidget() {
        model.widget.toggle()
        UserDefaults.standard.set(model.widget, forKey: "widgetVisible")
        if model.widget { resize(widgetPanel, width: model.dock ? 38 : 284); widgetPanel.orderFrontRegardless(); boostTracking() }
        else { widgetPanel.orderOut(nil) }
    }

    @objc func wake(_ notification: Notification) { model.refresh(); boostTracking() }
    @objc func workspaceChanged(_ notification: Notification) { boostTracking(); cachedPID = nil; trackedWindowID = nil }

    func trackingTick() {
        guard model.widget, model.dock || model.followVisibility, !draggingDock else { return }
        let now = CACurrentMediaTime()
        guard now >= nextQueryAt else { return }
        nextQueryAt = now + (now < fastUntil ? 1.0 / 60.0 : 0.10)
        followGPT()
    }

    func boostTracking() {
        fastUntil = CACurrentMediaTime() + 0.55
        nextQueryAt = 0
    }

    func targetApplication() -> NSRunningApplication? {
        if let pid = cachedPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated { return app }
        return NSWorkspace.shared.runningApplications.first {
            ["com.openai.chat", "com.openai.codex"].contains($0.bundleIdentifier ?? "") || ["ChatGPT", "Codex"].contains($0.localizedName ?? "")
        }
    }

    func followGPT() {
        guard !queryInFlight else { return }
        guard let target = targetApplication() else {
            setFollowStatus("等待 GPT 启动")
            if model.dock || model.followVisibility { widgetPanel.orderOut(nil) }
            return
        }
        if cachedPID != target.processIdentifier {
            cachedPID = target.processIdentifier
            trackedWindowID = nil
            lastBounds = nil
            installAXObserver(pid: target.processIdentifier)
        }
        let pid = target.processIdentifier
        let id = trackedWindowID
        let currentGeneration = generation
        queryInFlight = true
        trackingQueue.async { [weak self] in
            var snapshot = id.flatMap(targetWindow(id:))
            if snapshot == nil { snapshot = targetWindows(pid: pid).first(where: { $0.visible }) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryInFlight = false
                guard self.generation == currentGeneration, !self.draggingDock, self.cachedPID == pid else { return }
                if let snapshot { self.trackedWindowID = snapshot.id }
                self.apply(snapshot, target: target)
            }
        }
    }

    func apply(_ window: TargetWindow?, target: NSRunningApplication) {
        guard let window else {
            setFollowStatus("未读取到 GPT 主窗口")
            if model.dock || model.followVisibility { widgetPanel.orderOut(nil) }
            return
        }
        if target.isHidden || !window.visible {
            wasTargetActive = false
            setFollowStatus("随 GPT 隐藏")
            if widgetPanel.isVisible { widgetPanel.orderOut(nil) }
            return
        }
        if window.bounds != lastBounds {
            lastBounds = window.bounds
            boostTracking()
        }
        if model.dock { positionWidget(window.bounds) }
        setFollowStatus(model.dock ? "已吸附 GPT" : "跟随 GPT 显示")
        if !widgetPanel.isVisible { widgetPanel.orderFrontRegardless() }
        else if target.isActive && !wasTargetActive && !model.alwaysTop { widgetPanel.orderFrontRegardless() }
        wasTargetActive = target.isActive
        let level: NSWindow.Level = model.alwaysTop ? .floating : .normal
        if widgetPanel.level != level { widgetPanel.level = level }
    }

    func setFollowStatus(_ status: String) { if model.followStatus != status { model.followStatus = status } }

    func positionWidget(_ bounds: CGRect) {
        let originY = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = CGRect(x: bounds.minX, y: originY - bounds.maxY, width: bounds.width, height: bounds.height)
        let screen = NSScreen.screens.max { a, b in
            let aa = a.frame.intersection(rect), bb = b.frame.intersection(rect)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        }?.visibleFrame ?? NSScreen.main!.visibleFrame
        lastTargetRect = rect
        let point = dockOrigin(edge: model.dockEdge, fraction: model.dockFraction, target: rect, widget: widgetPanel.frame.size, screen: screen)
        if abs(widgetPanel.frame.minX - point.x) > 0.5 || abs(widgetPanel.frame.minY - point.y) > 0.5 { widgetPanel.setFrameOrigin(point) }
    }

    func dockDragBegan() {
        guard model.widget, model.dock else { return }
        generation += 1
        draggingDock = true
        dragStartOrigin = widgetPanel.frame.origin
    }
    func dockDragChanged(_ delta: CGSize) {
        guard draggingDock else { return }
        widgetPanel.setFrameOrigin(CGPoint(x: dragStartOrigin.x + delta.width, y: dragStartOrigin.y + delta.height))
    }
    func dockDragCancelled() {
        guard draggingDock else { return }
        widgetPanel.setFrameOrigin(dragStartOrigin)
        draggingDock = false
        generation += 1
        boostTracking()
    }
    func dockDragEnded(_ delta: CGSize) {
        guard draggingDock else { return }
        widgetPanel.setFrameOrigin(CGPoint(x: dragStartOrigin.x + delta.width, y: dragStartOrigin.y + delta.height))
        draggingDock = false
        generation += 1
        guard let target = lastTargetRect else { boostTracking(); return }
        let center = CGPoint(x: widgetPanel.frame.midX, y: widgetPanel.frame.midY)
        model.dockEdge = nearestDockEdge(point: center, target: target)
        model.dockFraction = model.dockEdge.isHorizontal
            ? max(0, min(1, (center.x - target.minX) / max(1, target.width)))
            : max(0, min(1, (center.y - target.minY) / max(1, target.height)))
        model.saveOptions()
        resize(widgetPanel, width: 38)
        boostTracking()
    }

    func installAXObserver(pid: pid_t) {
        if let observer = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        axObserver = nil; axApplication = nil; axWindow = nil; axPID = nil
        guard AXIsProcessTrusted() else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, accessibilityCallback, &observer) == .success, let observer else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString, context)
        AXObserverAddNotification(observer, application, kAXWindowCreatedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer; axApplication = application; axPID = pid
        observeFocusedWindow()
    }

    func observeFocusedWindow() {
        guard let observer = axObserver, let application = axApplication else { return }
        if let old = axWindow {
            [kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification].forEach {
                AXObserverRemoveNotification(observer, old, $0 as CFString)
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { axWindow = nil; return }
        let window = value as! AXUIElement
        let context = Unmanaged.passUnretained(self).toOpaque()
        [kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification].forEach {
            AXObserverAddNotification(observer, window, $0 as CFString, context)
        }
        axWindow = window
    }
}

if CommandLine.arguments.contains("--probe") {
    do {
        let data = try fetchQuotaData()
        let resetsText = resetCount(data).map { String($0) } ?? "unknown"
        print("Available resets: \(resetsText)")
        for quota in decodeQuotas(data) {
            let remainingText = quota.remaining.map { String($0) } ?? "unknown"
            print("\(quota.title): \(remainingText)% remaining")
        }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--diagnose-follow") {
    print("AX trusted: \(AXIsProcessTrusted())")
    for app in NSWorkspace.shared.runningApplications where ["com.openai.chat", "com.openai.codex"].contains(app.bundleIdentifier ?? "") {
        let windows = targetWindows(pid: app.processIdentifier)
        print("\(app.bundleIdentifier ?? "unknown"): \(windows.count) windows")
        windows.forEach { print("id=\($0.id) visible=\($0.visible) bounds=\($0.bounds)") }
    }
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    let quotas = decodeQuotas(["rateLimitsByLimitId": ["codex": [
        "primary": ["usedPercent": 27.0, "windowDurationMins": 300],
        "secondary": ["usedPercent": 130.0, "windowDurationMins": 10080]
    ]]])
    precondition(quotas.count == 2 && quotas[0].remaining == 73 && quotas[1].remaining == 0)
    precondition(resetCount([:]) == nil)
    precondition(resetCount(["rateLimitResetCredits": ["availableCount": 1]]) == 1)
    let screen = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    let target = CGRect(x: 100, y: 200, width: 500, height: 600)
    let vertical = CGSize(width: 38, height: 184)
    let first = dockOrigin(edge: .right, fraction: 0.5, target: target, widget: vertical, screen: screen)
    let moved = dockOrigin(edge: .right, fraction: 0.5, target: target.offsetBy(dx: 80, dy: 50), widget: vertical, screen: screen)
    precondition(moved.x - first.x == 80 && moved.y - first.y == 50)
    precondition(nearestDockEdge(point: CGPoint(x: 95, y: 500), target: target) == .left)
    precondition(nearestDockEdge(point: CGPoint(x: 350, y: 810), target: target) == .top)
    let top = dockOrigin(edge: .top, fraction: 0.5, target: target, widget: CGSize(width: 184, height: 38), screen: screen)
    precondition(top.y == 806)
    print("PASS: quota parsing, reset count, four-edge docking, orientation and window movement")
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
    _ = NSApplication.shared
    let model = MeterModel()
    if let data = try? fetchQuotaData() { model.quotas = decodeQuotas(data); model.resets = resetCount(data); model.updated = Date() }
    model.dock = CommandLine.arguments.contains("--rail")
    if CommandLine.arguments.contains("--left") { model.dockEdge = .left }
    if CommandLine.arguments.contains("--right") { model.dockEdge = .right }
    if CommandLine.arguments.contains("--top") { model.dockEdge = .top }
    if CommandLine.arguments.contains("--bottom") { model.dockEdge = .bottom }
    if CommandLine.arguments.contains("--dark") { model.theme = "dark" }
    if CommandLine.arguments.contains("--light") { model.theme = "light" }
    let view = NSHostingView(rootView: PanelContent(model: model, compact: model.dock, pin: {}, widget: {}))
    let length = CGFloat(28 + max(1, model.visibleItems.count) * 52)
    let size = model.dock ? (model.dockEdge.isHorizontal ? CGSize(width: length, height: 38) : CGSize(width: 38, height: length)) : CGSize(width: 340, height: 400)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.appearance = NSAppearance(named: model.theme == "dark" ? .darkAqua : .aqua)
    view.frame = CGRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    exit(0)
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
