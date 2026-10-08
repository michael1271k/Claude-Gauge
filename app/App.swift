// Claude Gauge entry: one presence at a time (menu bar or floating widget), plus build-time helpers.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  let store = Store()
  private(set) var widget: WidgetController!
  private(set) var statusBar: StatusBar!
  private var notificationClickedAt = Date.distantPast

  func applicationWillFinishLaunching(_ note: Notification) {
    UNUserNotificationCenter.current().delegate = self
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    if !UserDefaults.standard.bool(forKey: "loginConfigured") {
      UserDefaults.standard.set(true, forKey: "loginConfigured")
      try? SMAppService.mainApp.register()
    }
    Windows.store = store
    store.load()
    widget = WidgetController(store: store)
    statusBar = StatusBar(store: store)
    Task {
      var lastLoad = Date.distantPast
      while !Task.isCancelled {
        if Date().timeIntervalSince(lastLoad) > 0.8 {
          store.load()
          lastLoad = .now
        }
        if store.glow.animates || Date().timeIntervalSince(store.rippleAt) < 1.5 { store.frame &+= 1 }
        statusBar.refresh()
        try? await Task.sleep(for: .milliseconds(66))
      }
    }
  }

  /// Opening the app again (Finder, Spotlight) shows Settings: the way back when it is hidden.
  /// A notification click also counts as a reopen; it opens its chat instead.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
      if Date().timeIntervalSince(notificationClickedAt) > 1.5 { Windows.showSettings() }
    }
    return false
  }

  /// Clicking a "needs you" / "is done" notification opens that chat in Claude.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let id = response.notification.request.content.userInfo["session"] as? String
    await MainActor.run {
      notificationClickedAt = .now
      if let id { openChat(id: id) } else { openClaude() }
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }
}

@main struct GaugeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
  init() {
    let args = CommandLine.arguments
    if args.count == 3, args[1] == "--icon" {
      MainActor.assumeIsolated { writePNG(AppIconArt(), to: args[2], scale: 1) }
      exit(0)
    }
    if args.count == 3, args[1] == "--snapshot" {
      MainActor.assumeIsolated { snapshots(to: args[2]) }
      exit(0)
    }
    if args.contains("--selftest") {
      selfTest()
      exit(0)
    }
  }

  /// The menu bar item and widget are AppKit (see StatusBar and WidgetController); this scene is a placeholder.
  var body: some Scene {
    Settings { EmptyView() }
  }
}

/// The menu bar item: an NSStatusItem with a popover, so it works from the menu bar on every screen.
@MainActor final class StatusBar: NSObject {
  private let store: Store
  private var item: NSStatusItem?
  private let popover = NSPopover()
  private var lastKey = ""

  init(store: Store) {
    self.store = store
    super.init()
    let host = NSHostingController(rootView: MenuPanel(store: store).environment(\.colorScheme, .dark))
    host.sizingOptions = [.preferredContentSize]
    popover.contentViewController = host
    popover.behavior = .transient
    popover.appearance = NSAppearance(named: .darkAqua)
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.apply() }
    }
    apply()
  }

  /// Creating a status item writes its position to UserDefaults, which calls this again; the guard stops that loop.
  private var applying = false
  private func apply() {
    guard !applying else { return }
    applying = true
    defer { applying = false }
    let wanted = Prefs.placement == .menuBar
    if wanted, item == nil {
      let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      i.button?.target = self
      i.button?.action = #selector(toggle(_:))
      i.button?.toolTip = "Claude Gauge"
      item = i
      lastKey = ""
      refresh()
    } else if !wanted, let i = item {
      popover.performClose(nil)
      NSStatusBar.system.removeStatusItem(i)
      item = nil
    }
    lastKey = ""
  }

  /// Redraws the icon only when what it shows changed (every frame only while it animates).
  func refresh() {
    guard let button = item?.button else { return }
    let style = IconStyle(rawValue: Prefs.d.string(forKey: "iconStyle") ?? "") ?? .ring
    let moving = store.glow.animates || Date().timeIntervalSince(store.rippleAt) < 1.5
    let key = "\(style)|\(store.glow)|\(Int(store.five?.percentUsed ?? -1))|\(Int(store.week?.percentUsed ?? -1))|\(Prefs.d.string(forKey: "theme") ?? "")|\(moving ? store.frame : 0)"
    guard key != lastKey else { return }
    lastKey = key
    button.image = menuBarImage(store, style: style)
  }

  @objc private func toggle(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
    } else {
      NSApp.activate()
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }
}

// MARK: Build-time helpers

@MainActor func writePNG(_ view: some View, to path: String, scale: CGFloat = 2) {
  let r = ImageRenderer(content: view)
  r.scale = scale
  guard let tiff = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
  try? png.write(to: URL(fileURLWithPath: path))
}

/// Renders the main surfaces with sample data for design review (glass shows as the solid fallback offscreen).
@MainActor func snapshots(to dir: String) {
  UserDefaults.standard.set(true, forKey: "solidGlass")
  Greeting.override = "Alex"
  defer { UserDefaults.standard.removeObject(forKey: "solidGlass") }
  let store = Store.sample()
  let dark = { (v: AnyView) in v.environment(\.colorScheme, .dark) }
  var marks: [AnyView] = []
  for style in IconStyle.allCases {
    for glow in [Glow.idle, .working, .waiting, .done] {
      marks.append(AnyView(GaugeMark(style: style, glow: glow, pct: 58, week: 74, time: 0.7, rippleAge: glow == .done ? 0.3 : .infinity).frame(width: 40, height: 40)))
    }
  }
  writePNG(dark(AnyView(LazyVGrid(columns: Array(repeating: GridItem(.fixed(56)), count: 4), spacing: 16) { ForEach(marks.indices, id: \.self) { marks[$0] } }
    .padding(20).background(Color(white: 0.08)))), to: "\(dir)/marks.png")
  store.setSample(.waiting)
  writePNG(dark(AnyView(PeekCard(store: store).frame(width: 300).glassCard(tint: Palette.waiting).padding(24).background(Color(white: 0.3)))), to: "\(dir)/peek.png")
  writePNG(dark(AnyView(MenuPanel(store: store).background(Color(white: 0.12)))), to: "\(dir)/panel.png")
  store.setSample(.working)
  let belt = WidgetModel()
  writePNG(dark(AnyView(HStack(alignment: .top, spacing: 18) {
    AgentBelt(store: store, model: belt, vertical: true).glassCard(radius: 14)
    AgentBelt(store: store, model: belt, vertical: false).glassCard(radius: 18)
    VStack(spacing: 12) {
      ChatPeek(chat: store.chats[0], store: store).frame(width: 300).glassCard(radius: 20)
      PeekCard(store: store).frame(width: 300).glassCard(radius: 20)
    }
  }.padding(20).background(Color(white: 0.3)))), to: "\(dir)/belt.png")
  writePNG(dark(AnyView(PromptPad().frame(width: 380, height: 300).background(Color(white: 0.12)))), to: "\(dir)/pad.png")
  writePNG(dark(AnyView(VStack(spacing: 14) {
    AgentsView(store: store)
    ForEach(LimitsStyle.allCases) { st in
      Group {
        switch st {
        case .rings: LimitRing(title: "5-hour", limit: store.five)
        case .bars, .marker: LimitBar(title: "Weekly", limit: store.week, marker: st == .marker)
        case .nested: NestedRings(five: store.five, week: store.week)
        }
      }
    }
  }.padding(18).frame(width: 380).background(Color(white: 0.12)))), to: "\(dir)/agents.png")
}

extension Store {
  static func sample() -> Store {
    let s = Store()
    let now = Date().timeIntervalSince1970 * 1000
    let limits = [Limit(kind: "five_hour", percentUsed: 38, resetsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(8000))),
                  Limit(kind: "seven_day", percentUsed: 74, resetsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(300_000)))]
    s.chats = [
      Chat(id: "d", cwd: "/Users/me/Code/api", project: "api", label: "", usd: 3.2, at: now - 30_000, state: .waiting, stateAt: now - 30_000, question: "Which database should the cache use?", title: "Add a cache layer"),
      Chat(id: "a", cwd: "/Users/me/Code/atlas", project: "atlas", label: "fix login", usd: 1.84, at: now - 60_000, limits: limits, state: .working, stateAt: now - 60_000, title: "Fix the login redirect loop"),
      Chat(id: "b", cwd: "/Users/me/Code/notes", project: "notes", label: "", usd: 0.42, at: now - 600_000, state: .done, stateAt: now - 600_000, title: "Sync notes to iCloud"),
      Chat(id: "c", cwd: "/Users/me/Code/site", project: "site", label: "landing copy", usd: 12.3, at: now - 7_200_000, state: .idle, stateAt: now - 7_200_000),
    ]
    let cal = Calendar.current
    s.days = (0..<30).map { back in
      Day(date: cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: .now))!, usd: [3.1, 2.4, 6.1, 3.3, 9.8, 0, 1.2, 4.4, 12.6, 7.7][back % 10])
    }
    s.updatedAt = now - 60_000
    s.limits = limits
    s.spend = ["a": ChatSpend(byDay: [dayKey(.now): 1.2], total: 1.84, model: "claude-opus-5-5", effort: "high"),
               "b": ChatSpend(byDay: [dayKey(.now): 0.42], total: 0.42, model: "claude-haiku-4-5-20251001", effort: "medium")]
    let now2 = Date()
    s.activity["a"] = Activity(prompt: "Fix the login redirect loop and add a regression test for the OAuth callback", promptAt: now2.addingTimeInterval(-840),
      doing: "Editing AuthCallback.swift", recent: ["Reading AuthCallback.swift", "Running the auth tests", "Editing AuthCallback.swift"], tools: 37, agents: [
        SubAgent(id: "1", kind: "Explore", task: "Map the auth flow", started: now2.addingTimeInterval(-800), finished: now2.addingTimeInterval(-500)),
        SubAgent(id: "2", kind: "general-purpose", task: "Write the regression test", started: now2.addingTimeInterval(-300))])
    return s
  }

  func setSample(_ glow: Glow) {
    guard !chats.isEmpty else { return }
    let state: ChatState = glow == .waiting ? .waiting : glow == .done ? .done : .working
    chats[0].state = state
    chats[0].stateAt = nowMs
    chats[0].question = state == .waiting ? "Which database should the cache use?" : ""
  }
}

func selfTest() {
  func chat(_ state: ChatState, at: Double, stateAt: Double) -> Chat {
    Chat(id: UUID().uuidString, cwd: "/x", project: "x", label: "", usd: 0, at: at, state: state, stateAt: stateAt)
  }
  let now = 1_000_000_000_000.0, min = 60_000.0
  precondition(Glow.of([], seenAt: 0, maxPct: 10, now: now) == .idle)
  precondition(Glow.of([], seenAt: 0, maxPct: 85, now: now) == .hot)
  precondition(Glow.of([chat(.working, at: now, stateAt: now - min)], seenAt: 0, maxPct: 0, now: now) == .working)
  precondition(Glow.of([chat(.working, at: now, stateAt: now - 31 * min)], seenAt: 0, maxPct: 0, now: now) == .idle, "stale working is idle")
  precondition(Glow.of([chat(.working, at: now, stateAt: now), chat(.waiting, at: now, stateAt: now)], seenAt: 0, maxPct: 0, now: now) == .waiting)
  precondition(Glow.of([chat(.done, at: now, stateAt: now - min)], seenAt: now - 2 * min, maxPct: 0, now: now) == .done)
  precondition(Glow.of([chat(.done, at: now, stateAt: now - min)], seenAt: now, maxPct: 0, now: now) == .idle, "seen done is idle")
  precondition(Greeting.salutation(hour: 6) == "Good morning" && Greeting.salutation(hour: 13) == "Good afternoon")
  precondition(Greeting.salutation(hour: 19) == "Good evening" && Greeting.salutation(hour: 2) == "Good night")
  precondition(minutesLeft(samples: [(0, 10), (600, 20)]) == 80, "10%/10min leaves 80 min")
  precondition(minutesLeft(samples: [(0, 20), (600, 20)]) == nil)
  let c = Chat(id: "s", cwd: "/Users/a b/Library/Application Support/x", project: "", label: "", usd: 0, at: 0, state: .idle, stateAt: 0)
  precondition(c.transcriptURL.path.hasSuffix("/-Users-a-b-Library-Application-Support-x/s.jsonl"), c.transcriptURL.path)
  let split = Ledger.allocate(cost: ["opus": 10, "haiku": 2], weights: ["opus": ["d1": 1, "d2": 3], "sonnet": ["d3": 1]])
  precondition(abs(split["d1"]! - 2.9) < 1e-9 && abs(split["d2"]! - 8.7) < 1e-9 && abs(split["d3"]! - 0.4) < 1e-9, "allocation \(split)")
  precondition(modelLabel("claude-opus-5-5", effort: "xhigh") == "Opus 5.5 · Extra high")
  precondition(modelLabel("claude-haiku-4-5-20251001", effort: "") == "Haiku 4.5", modelLabel("claude-haiku-4-5-20251001", effort: ""))
  print("selftest ok")
}
