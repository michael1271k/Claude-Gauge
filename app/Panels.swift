// Menu bar panel, Dashboard and Settings windows.
import ServiceManagement
import SwiftUI

/// Settings and Dashboard as plain windows, so both the menu bar panel and the widget can open them.
@MainActor enum Windows {
  private static var settings: NSWindow?
  private static var dashboard: NSWindow?
  static weak var store: Store?

  static func showSettings() {
    settings = settings ?? make("Claude Gauge Settings", SettingsView(), size: NSSize(width: 460, height: 640))
    present(settings!)
  }

  static func showDashboard() {
    guard let store else { return }
    dashboard = dashboard ?? make("Claude Gauge", Dashboard(store: store), size: NSSize(width: 760, height: 760))
    present(dashboard!)
  }

  private static var pad: NSPanel?

  /// Prompt Pad: a floating window that takes typing without pulling Claude Gauge to the front.
  static func showPad() {
    if pad == nil {
      let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                      styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
      p.title = "Prompt Pad"
      p.isFloatingPanel = true
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.appearance = NSAppearance(named: .darkAqua)
      p.contentViewController = NSHostingController(rootView: PromptPad().environment(\.colorScheme, .dark))
      p.center()
      pad = p
    }
    pad?.makeKeyAndOrderFront(nil)
  }

  private static func make(_ title: String, _ view: some View, size: NSSize) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .darkAqua)
    w.contentViewController = NSHostingController(rootView: view.environment(\.colorScheme, .dark))
    w.center()
    return w
  }

  private static func present(_ w: NSWindow) {
    NSApp.activate()
    w.makeKeyAndOrderFront(nil)
  }
}

struct MenuPanel: View {
  let store: Store
  @AppStorage("tab") private var tab = GaugeTab.overview.rawValue
  @AppStorage("theme") private var theme = "Ocean"

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Header(store: store) { EmptyView() }
      TabSwitch(tab: $tab, agents: store.agentChats.count)
      if tab == GaugeTab.agents.rawValue {
        AgentsView(store: store)
      } else {
        LimitsView(store: store)
        SpendChart(store: store, days: 30)
        ChatsView(store: store)
      }
      GaugeToolbar {
        SyncButton(store: store)
        IconButton(symbol: "macwindow.on.rectangle", hint: "Float it on the screen") { Prefs.d.set(Placement.floating.rawValue, forKey: "placement") }
        IconButton(symbol: "chart.bar.xaxis", hint: "Dashboard") { Windows.showDashboard() }
        IconButton(symbol: "gearshape", hint: "Settings") { Windows.showSettings() }
        IconButton(symbol: "power", hint: "Quit Claude Gauge") { NSApp.terminate(nil) }
      }
    }
    .padding(16)
    .frame(width: 380)
    .tint(Palette.accent)
    .id(theme)
    .onAppear { store.markSeen() }
  }
}

struct Dashboard: View {
  let store: Store

  var body: some View {
    let projects = Dictionary(grouping: store.chats, by: \.displayProject)
      .map { (name: $0.key, usd: $0.value.reduce(0) { $0 + $1.usd }, chats: $0.value.count) }
      .sorted { $0.usd > $1.usd }
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Header(store: store) { EmptyView() }
        HStack(alignment: .top, spacing: 36) {
          LimitsView(store: store, ringSize: 96).frame(width: 300)
          VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "By project")
            ForEach(projects.prefix(6), id: \.name) { p in
              HStack {
                Text(p.name).font(.system(size: 12, weight: .medium))
                Text("\(p.chats) chat\(p.chats == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.money(p.usd)).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
              }
            }
          }
        }
        CostTiles(store: store)
        SpendChart(store: store, days: 30, height: 180, showTotals: false)
        SectionLabel(text: "Chats this week")
        Table(store.rankedChats) {
          TableColumn("") { c in stateIcon(c.liveState(now: store.nowMs)).foregroundStyle(Palette.state(c.liveState(now: store.nowMs))) }.width(18)
          TableColumn("Chat") { Text($0.displayTitle) }
          TableColumn("Project") { Text($0.displayProject).foregroundStyle(.secondary) }.width(140)
          TableColumn("Active") { Text(Format.ago($0.at)) }.width(60)
          TableColumn("Cost") { Text(Format.money($0.usd)).monospacedDigit() }.width(70)
        }
        .frame(minHeight: 240)
      }
      .padding(28)
    }
    .frame(minWidth: 720, minHeight: 640)
    .tint(Palette.accent)
  }
}

struct SettingsView: View {
  @AppStorage("placement") private var placement = Placement.menuBar.rawValue
  @AppStorage("widgetShow") private var show = WidgetShow.withClaude.rawValue
  @AppStorage("widgetForm") private var form = WidgetForm.edge.rawValue
  @AppStorage("weekStart") private var weekStart = "Sunday"
  @AppStorage("widgetScreens") private var screens = "1"
  @AppStorage("edgeSide") private var side = EdgeSide.right.rawValue
  @AppStorage("pinOnTop") private var pinOnTop = true
  @AppStorage("keepExpanded") private var keepExpanded = false
  @AppStorage("autoOpenOnInput") private var autoOpen = true
  @AppStorage("iconStyle") private var iconStyle = IconStyle.ring.rawValue
  @AppStorage("theme") private var theme = "Ocean"
  @AppStorage("customAccent") private var customAccent = 0x63D1FF
  @AppStorage("customSecondary") private var customSecondary = 0xFFD63F
  @AppStorage("limitsStyle") private var limits = LimitsStyle.rings.rawValue
  @AppStorage("solidGlass") private var solid = false
  @AppStorage("soundsOn") private var soundsOn = true
  @AppStorage("soundWaiting") private var soundWaiting = "Glass"
  @AppStorage("soundRunning") private var soundRunning = "None"
  @AppStorage("soundDone") private var soundDone = "Hero"
  @AppStorage("notificationsOn") private var notificationsOn = true
  @State private var atLogin = SMAppService.mainApp.status == .enabled

  private let sounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Funk", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Tink", "None"]

  var body: some View {
    Form {
      Section("Where") {
        Picker("Claude Gauge lives in", selection: $placement) { ForEach(Placement.allCases) { Text($0.rawValue).tag($0.rawValue) } }
          .pickerStyle(.segmented)
        if placement == Placement.floating.rawValue {
          Picker("Show", selection: $show) { ForEach(WidgetShow.allCases) { Text($0.rawValue).tag($0.rawValue) } }
          Picker("Screen", selection: $screens) {
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, s in Text("\(i + 1). \(s.localizedName)").tag("\(i + 1)") }
            Text("All screens").tag("all")
          }
          Picker("Style", selection: $form) { ForEach(WidgetForm.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented)
          if form == WidgetForm.edge.rawValue {
            Picker("Screen edge", selection: $side) { ForEach(EdgeSide.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented)
          }
          Toggle("Pin on top of other windows", isOn: $pinOnTop)
          Toggle("Keep expanded", isOn: $keepExpanded)
          Toggle("Open by itself when a chat needs input", isOn: $autoOpen)
          Text("Drag it anywhere: near the left or right edge it becomes the edge belt, near the bottom the Dock shelf, anywhere else it floats. Drop it on another screen to move it there. Hover a bead to peek at that chat, click for details.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Look") {
        Picker("Appearance", selection: $theme) {
          ForEach(Theme.all) { Text($0.id).tag($0.id) }
          Text("Custom").tag("Custom")
        }
        HStack(spacing: 6) {
          ForEach(Theme.all) { t in
            Button { theme = t.id } label: {
              HStack(spacing: 0) { t.accent; t.secondary }.frame(width: 34, height: 18).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white, lineWidth: theme == t.id ? 2 : 0))
            }
            .buttonStyle(.plain).help(t.id).accessibilityLabel(t.id)
          }
        }
        if theme == "Custom" {
          ColorPicker("Main color", selection: Binding(get: { Color(hex: customAccent) }, set: { customAccent = $0.hex }), supportsOpacity: false)
          ColorPicker("Secondary color", selection: Binding(get: { Color(hex: customSecondary) }, set: { customSecondary = $0.hex }), supportsOpacity: false)
        }
        Picker("Icon", selection: $iconStyle) { ForEach(IconStyle.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented)
        HStack(spacing: 18) {
          ForEach(IconStyle.allCases) { s in
            Button { iconStyle = s.rawValue } label: {
              GaugeMark(style: s, glow: .idle, pct: 42, week: 74, still: true).frame(width: 26, height: 26)
                .opacity(iconStyle == s.rawValue ? 1 : 0.4)
            }
            .buttonStyle(.plain).help(s.detail).accessibilityLabel(s.rawValue)
          }
        }
        Text((IconStyle(rawValue: iconStyle) ?? .ring).detail).font(.caption).foregroundStyle(.secondary)
        Picker("Limits", selection: $limits) { ForEach(LimitsStyle.allCases) { Text($0.rawValue).tag($0.rawValue) } }
        Text("Bars + time adds a tick for how much of each window has passed: a bar ahead of its tick means you're using it faster than it refills.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Solid background instead of glass", isOn: $solid)
      }
      Section("Sounds and alerts") {
        Toggle("Sounds", isOn: $soundsOn)
        soundPicker("Needs input", $soundWaiting).disabled(!soundsOn)
        soundPicker("Running", $soundRunning).disabled(!soundsOn)
        soundPicker("Finished", $soundDone).disabled(!soundsOn)
        Toggle("Notifications (click one to open its chat)", isOn: $notificationsOn)
      }
      Section("Spend") {
        Picker("Week starts on", selection: $weekStart) { Text("Sunday").tag("Sunday"); Text("Monday").tag("Monday") }.pickerStyle(.segmented)
        Text("Today resets at midnight, the week on \(weekStart), the month on the 1st. Costs come from Claude's own chat logs, so reopening an old chat never counts it twice.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("General") {
        Toggle("Open Claude Gauge at login", isOn: $atLogin)
          .onChange(of: atLogin) { _, on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        Text("Reads what the gauge mod writes to ~/.claude/gauge. Nothing leaves your Mac.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .id(theme == "Custom" ? "\(theme)\(customAccent)\(customSecondary)" : theme)
    .frame(minWidth: 440, minHeight: 560)
    .tint(Palette.accent)
  }

  private func soundPicker(_ title: String, _ value: Binding<String>) -> some View {
    HStack {
      Picker(title, selection: value) { ForEach(sounds, id: \.self) { Text($0).tag($0) } }
      Button { NSSound(named: value.wrappedValue)?.play() } label: { Image(systemName: "play.fill") }
        .buttonStyle(.borderless).help("Preview").disabled(value.wrappedValue == "None")
    }
  }
}

/// Asks every open chat to re-read its usage and re-counts spend; spins while it settles.
struct SyncButton: View {
  let store: Store
  var body: some View {
    let busy = Date().timeIntervalSince(store.syncedAt) < 10
    IconButton(symbol: "arrow.triangle.2.circlepath", hint: busy ? "Syncing with your open chats…" : "Sync now") { store.sync() }
      .symbolEffect(.pulse, isActive: busy)
  }
}
