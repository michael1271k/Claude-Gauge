// The floating Gauge widget: one glass panel per chosen screen, in one of three forms
// (capsule or edge tab). Hover peeks and stays open while the pointer is on it; click opens fully.
import AppKit
import SwiftUI

enum Placement: String, CaseIterable, Identifiable {
  case menuBar = "Menu bar", floating = "Floating on screen"
  var id: String { rawValue }
}

enum WidgetForm: String, CaseIterable, Identifiable {
  case edge = "Snap to edge", capsule = "Floating"
  var id: String { rawValue }
}

enum WidgetShow: String, CaseIterable, Identifiable {
  case withClaude = "When Claude is open", always = "Always"
  var id: String { rawValue }
}

enum EdgeSide: String, CaseIterable, Identifiable {
  case right = "Right", left = "Left"
  var id: String { rawValue }
}

enum Expansion { case collapsed, peek, full }

enum Prefs {
  static var d: UserDefaults { .standard }
  static var placement: Placement { Placement(rawValue: d.string(forKey: "placement") ?? "") ?? .menuBar }
  static var form: WidgetForm { WidgetForm(rawValue: d.string(forKey: "widgetForm") ?? "") ?? .edge }
  static var show: WidgetShow { WidgetShow(rawValue: d.string(forKey: "widgetShow") ?? "") ?? .withClaude }
  static var side: EdgeSide { EdgeSide(rawValue: d.string(forKey: "edgeSide") ?? "") ?? .right }
  /// "all", or a 1-based screen number ("1" is the screen with the menu bar).
  static var screens: String { d.string(forKey: "widgetScreens") ?? "1" }
  static var pinOnTop: Bool { d.object(forKey: "pinOnTop") as? Bool ?? true }
  static var keepExpanded: Bool { d.bool(forKey: "keepExpanded") }
  static var autoOpen: Bool { d.object(forKey: "autoOpenOnInput") as? Bool ?? true }
}

@MainActor @Observable final class WidgetModel {
  var expansion: Expansion = .collapsed
  /// Where the content sits inside the (larger, transparent) panel; it grows away from this point.
  var anchor: Alignment = .topTrailing
  /// The content's frame in panel coordinates (top-left origin), reported by SwiftUI.
  var contentFrame: CGRect = .zero
  /// SwiftUI's own hover over the card.
  var hovering = false
  /// While dragged it is always the small floating capsule.
  var dragging = false
}

let widgetPanelSize = NSSize(width: 420, height: 760)
let widgetSpring = Animation.spring(response: 0.35, dampingFraction: 1)

final class PassivePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  /// Let it sit flush against any screen edge.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstClickHostingView<V: View>: NSHostingView<V> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One widget on one screen.
@MainActor final class WidgetInstance {
  let screenID: String
  let model = WidgetModel()
  let panel: PassivePanel
  unowned let controller: WidgetController
  private var hoverSince: Date?
  private var awaySince: Date?
  private var changedAt = Date.distantPast
  /// Union of every frame the card had since it last opened, so a card mid-animation never "loses" the pointer.
  private var stickyRect: CGRect = .null
  /// Pointer offset from the capsule's center while dragging.
  private var grab: CGVector?

  init(screenID: String, store: Store, controller: WidgetController) {
    self.screenID = screenID
    self.controller = controller
    panel = PassivePanel(contentRect: NSRect(origin: .zero, size: widgetPanelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = FirstClickHostingView(rootView: WidgetRoot(store: store, model: model, instance: self))
    if Prefs.keepExpanded { model.expansion = .peek }
  }

  var screen: NSScreen? { NSScreen.screens.first { Self.id(of: $0) == screenID } }
  static func id(of s: NSScreen) -> String { "\((s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)" }

  func set(_ e: Expansion) {
    let target: Expansion = e == .collapsed && Prefs.keepExpanded ? .peek : e
    guard model.expansion != target else { return }
    if target == .full { controller.store.markSeen() }
    changedAt = .now
    if target == .collapsed { stickyRect = .null }
    withAnimation(widgetSpring) { model.expansion = target }
  }

  func tap() { set(model.expansion == .full ? .collapsed : .full) }

  func contentScreenRect() -> CGRect {
    let f = model.contentFrame
    return CGRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
  }

  /// Polled ~12×/s. Open on hover, stay open while the pointer is anywhere on the card.
  func pollHover() {
    guard grab == nil, panel.isVisible else { return }
    let rect = contentScreenRect()
    if model.expansion != .collapsed { stickyRect = stickyRect.union(rect) }
    let mouse = NSEvent.mouseLocation
    let inside = model.hovering || rect.insetBy(dx: -8, dy: -8).contains(mouse)
      || (model.expansion != .collapsed && stickyRect.insetBy(dx: -8, dy: -8).contains(mouse))
    let now = Date()
    if now.timeIntervalSince(changedAt) < 0.4 { return } // let the spring settle before judging
    if inside {
      awaySince = nil
      if hoverSince == nil { hoverSince = now }
      if model.expansion == .collapsed, now.timeIntervalSince(hoverSince!) > 0.12 { set(.peek) }
    } else {
      hoverSince = nil
      if awaySince == nil { awaySince = now }
      if model.expansion == .peek, now.timeIntervalSince(awaySince!) > 0.5 { set(.collapsed) }
    }
  }

  // MARK: Drag: any form shrinks to the capsule and follows the pointer; the drop spot picks the form.

  func dragChanged() {
    let mouse = NSEvent.mouseLocation
    if grab == nil {
      let c = contentScreenRect()
      grab = model.expansion == .collapsed && Prefs.form == .capsule ? CGVector(dx: mouse.x - c.midX, dy: mouse.y - c.midY) : .zero
      stickyRect = .null
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) {
        model.dragging = true
        model.expansion = .collapsed
        model.anchor = .center
      }
      panel.level = .floating
    }
    let g = grab ?? .zero
    panel.setFrameOrigin(NSPoint(x: mouse.x - g.dx - widgetPanelSize.width / 2, y: mouse.y - g.dy - widgetPanelSize.height / 2))
  }

  /// Near the left or right edge: docks there. Anywhere else: floats right there.
  func dragEnded() {
    guard grab != nil else { return }
    grab = nil
    let mouse = NSEvent.mouseLocation
    guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? screen else { return }
    let vis = target.visibleFrame
    let c = contentScreenRect()
    let id = Self.id(of: target)
    let d = Prefs.d
    if c.minX - vis.minX < 60 || vis.maxX - c.maxX < 60 {
      d.set((c.midY - vis.minY) / vis.height, forKey: "edgeY.\(id)")
      d.set((c.midX < vis.midX ? EdgeSide.left : .right).rawValue, forKey: "edgeSide")
      d.set(WidgetForm.edge.rawValue, forKey: "widgetForm")
    } else {
      d.set([(c.minX - vis.minX) / vis.width, (c.minY - vis.minY) / vis.height], forKey: "capsule.\(id)")
      d.set(WidgetForm.capsule.rawValue, forKey: "widgetForm")
    }
    if Prefs.screens != "all", let i = NSScreen.screens.firstIndex(of: target) { d.set("\(i + 1)", forKey: "widgetScreens") }
    model.dragging = false
    controller.apply(force: true)
  }

  private func setFrame(content c: CGRect, animate: Bool = false) {
    let pad = WidgetRoot.padding, a = model.anchor
    let x = a.horizontal == .leading ? c.minX - pad : a.horizontal == .trailing ? c.maxX + pad - widgetPanelSize.width : c.midX - widgetPanelSize.width / 2
    let y = a.vertical == .top ? c.maxY + pad - widgetPanelSize.height : a.vertical == .bottom ? c.minY - pad : c.midY - widgetPanelSize.height / 2
    panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: widgetPanelSize), display: true, animate: animate)
  }

  func place() {
    guard let screen else { return }
    let vis = screen.visibleFrame
    var t = Transaction()
    t.disablesAnimations = true
    let measured = model.contentFrame.size
    switch Prefs.form {
    case .capsule:
      let size = model.expansion == .collapsed && measured.width > 0 && measured.width < 200 ? measured : CGSize(width: 110, height: 34)
      let saved = Prefs.d.array(forKey: "capsule.\(screenID)") as? [Double]
      var c = CGRect(x: saved.map { vis.minX + $0[0] * vis.width } ?? vis.maxX - 12 - size.width,
                     y: saved.map { vis.minY + $0[1] * vis.height } ?? vis.maxY - 12 - size.height,
                     width: size.width, height: size.height)
      c.origin.x = min(max(c.minX, vis.minX + 6), vis.maxX - 6 - size.width)
      c.origin.y = min(max(c.minY, vis.minY + 6), vis.maxY - 6 - size.height)
      let right = c.midX > vis.midX, top = c.midY > vis.midY
      withTransaction(t) {
        model.anchor = top ? (right ? .topTrailing : .topLeading) : (right ? .bottomTrailing : .bottomLeading)
      }
      setFrame(content: c)
    case .edge:
      let right = Prefs.side == .right
      let size = CGSize(width: 34, height: 62)
      let f = Prefs.d.object(forKey: "edgeY.\(screenID)") as? Double ?? 0.62
      let cy = min(max(vis.minY + f * vis.height, vis.minY + size.height / 2 + 6), vis.maxY - size.height / 2 - 6)
      let c = CGRect(x: right ? vis.maxX - size.width : vis.minX, y: cy - size.height / 2, width: size.width, height: size.height)
      // The open card grows down from a tab in the top third, up from one in the bottom third, else both ways.
      let third = (cy - vis.minY) / vis.height
      let v: VerticalAlignment = third > 0.66 ? .top : third < 0.34 ? .bottom : .center
      withTransaction(t) {
        model.anchor = Alignment(horizontal: right ? .trailing : .leading, vertical: v)
      }
      setFrame(content: c)
    }
    applyLevel()
  }

  func applyLevel() { panel.level = Prefs.pinOnTop ? .floating : .normal }
}

@MainActor final class WidgetController {
  let store: Store
  private(set) var instances: [WidgetInstance] = []
  private var claudeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty
  private var poller: Timer?
  private var clickMonitor: Any?
  private var lastNeedsInput = Date.distantPast
  private var lastSignature = ""

  init(store: Store) {
    self.store = store
    let ws = NSWorkspace.shared.notificationCenter
    for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false)] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == claudeBundleID else { return }
        MainActor.assumeIsolated {
          self?.claudeRunning = running
          self?.apply()
        }
      }
    }
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.apply() }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.apply(force: true) }
    }
    apply()
  }

  private var targetScreens: [NSScreen] {
    let all = NSScreen.screens
    if Prefs.screens == "all" { return all }
    let i = (Int(Prefs.screens) ?? 1) - 1
    return [all.indices.contains(i) ? all[i] : all.first].compactMap { $0 }
  }

  /// Rebuild or update the widgets to match Settings, Claude running, and the connected screens.
  func apply(force: Bool = false) {
    let visible = Prefs.placement == .floating && (Prefs.show == .always || claudeRunning)
    let ids = visible ? targetScreens.map(WidgetInstance.id(of:)) : []
    let signature = ids.joined(separator: ",") + "|\(Prefs.form.rawValue)|\(Prefs.side.rawValue)"
    if force || signature != lastSignature {
      lastSignature = signature
      instances.filter { !ids.contains($0.screenID) }.forEach { $0.panel.orderOut(nil) }
      instances = ids.map { id in instances.first { $0.screenID == id } ?? WidgetInstance(screenID: id, store: store, controller: self) }
      instances.forEach { $0.place() }
    }
    for i in instances {
      i.applyLevel()
      if Prefs.keepExpanded, i.model.expansion == .collapsed { i.set(.peek) }
      i.panel.orderFrontRegardless()
    }
    instances.isEmpty ? stopPolling() : startPolling()
  }

  private func startPolling() {
    guard poller == nil else { return }
    poller = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated { self?.instances.filter { $0.model.expansion == .full }.forEach { $0.set(.collapsed) } }
    }
  }

  private func stopPolling() {
    poller?.invalidate()
    poller = nil
    if let m = clickMonitor { NSEvent.removeMonitor(m) }
    clickMonitor = nil
  }

  private func tick() {
    instances.forEach { $0.pollHover() }
    // A chat now needs input: open every widget so it can't be missed.
    if store.needsInputAt > lastNeedsInput {
      lastNeedsInput = store.needsInputAt
      if Prefs.autoOpen { instances.forEach { $0.set(.full) } }
    }
  }
}

struct WidgetRoot: View {
  static let padding: CGFloat = 24
  let store: Store
  let model: WidgetModel
  let instance: WidgetInstance
  @AppStorage("widgetForm") private var formRaw = WidgetForm.edge.rawValue
  @AppStorage("edgeSide") private var sideRaw = EdgeSide.right.rawValue
  @AppStorage("theme") private var theme = "Ocean"

  private var form: WidgetForm { model.dragging ? .capsule : WidgetForm(rawValue: formRaw) ?? .edge }
  private var unitAnchor: UnitPoint {
    UnitPoint(x: model.anchor.horizontal == .leading ? 0 : model.anchor.horizontal == .trailing ? 1 : 0.5,
              y: model.anchor.vertical == .top ? 0 : model.anchor.vertical == .bottom ? 1 : 0.5)
  }

  var body: some View {
    ZStack(alignment: model.anchor) {
      Color.clear
      card
        .background(GeometryReader { g in Color.clear.preference(key: ContentFrameKey.self, value: g.frame(in: .global)) })
        .onHover { model.hovering = $0 }
    }
    .padding(Self.padding)
    .frame(width: widgetPanelSize.width, height: widgetPanelSize.height)
    .onPreferenceChange(ContentFrameKey.self) { model.contentFrame = $0 }
    .environment(\.colorScheme, .dark)
    .tint(Palette.accent)
    .id(theme)
  }

  @ViewBuilder private var card: some View {
    Group {
      switch model.expansion {
      case .collapsed: collapsed
      case .peek: PeekCard(store: store).frame(width: 300)
      case .full: FullCard(store: store, instance: instance).frame(width: 360)
      }
    }
    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: unitAnchor)), removal: .opacity))
    .modifier(CardChrome(form: form, side: EdgeSide(rawValue: sideRaw) ?? .right, collapsed: model.expansion == .collapsed, glow: store.glow))
    .contentShape(Rectangle())
    .onTapGesture { if model.expansion != .full { instance.tap() } }
    .gesture(DragGesture(minimumDistance: 4).onChanged { _ in instance.dragChanged() }.onEnded { _ in instance.dragEnded() })
    .animation(widgetSpring, value: model.expansion)
  }

  @ViewBuilder private var collapsed: some View {
    let pct = store.five.map { "\(Int($0.percentUsed.rounded()))%" } ?? "–"
    switch form {
    case .capsule:
      HStack(spacing: 7) {
        LiveMark(store: store).frame(width: 18, height: 18)
        Text("Gauge").font(.system(size: 11, weight: .semibold))
        Text(pct).font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 11).padding(.vertical, 8)
    case .edge:
      VStack(spacing: 6) {
        LiveMark(store: store).frame(width: 18, height: 18)
        Text(pct).font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
      }
      .frame(width: 34, height: 62)
    }
  }
}

private struct ContentFrameKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Glass everywhere; square on the side that touches the screen edge.
private struct CardChrome: ViewModifier {
  let form: WidgetForm
  let side: EdgeSide
  let collapsed: Bool
  let glow: Glow
  func body(content: Content) -> some View {
    let tint = glow == .idle ? Color.clear : glow.color
    let r: CGFloat = collapsed ? 14 : 20
    switch form {
    case .edge:
      content.glassCard(corners: side == .right ? .init(topLeading: r, bottomLeading: r, bottomTrailing: 0, topTrailing: 0)
                                                : .init(topLeading: 0, bottomLeading: 0, bottomTrailing: r, topTrailing: r), tint: tint)
    case .capsule:
      content.glassCard(radius: collapsed ? 18 : 20, tint: tint)
    }
  }
}

struct PeekCard: View {
  let store: Store
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        LiveMark(store: store).frame(width: 22, height: 22)
        Text("Claude Gauge").font(.system(size: 13, weight: .semibold))
        Spacer()
        StateBadge(glow: store.glow)
      }
      VStack(spacing: 6) {
        LimitBar(title: "5-hour", limit: store.five)
        LimitBar(title: "Weekly", limit: store.week)
      }
      if let c = store.rankedChats.first { ChatRow(chat: c, store: store, highlight: true).padding(.horizontal, -8) }
      Text("Click for details").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
    }
    .padding(14)
  }
}

struct FullCard: View {
  let store: Store
  let instance: WidgetInstance
  @AppStorage("pinOnTop") private var pinOnTop = true
  @AppStorage("keepExpanded") private var keepExpanded = false
  @AppStorage("tab") private var tab = GaugeTab.overview.rawValue

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Header(store: store) {
        IconButton(symbol: "chevron.compact.up", hint: "Collapse") { instance.set(.collapsed) }
          .font(.system(size: 14, weight: .semibold))
      }
      TabSwitch(tab: $tab, agents: store.agentChats.count)
      if tab == GaugeTab.agents.rawValue {
        AgentsView(store: store)
      } else {
        LimitsView(store: store, ringSize: 58)
        SpendChart(store: store, days: 30)
        ChatsView(store: store)
      }
      Divider().opacity(0.4)
      HStack(spacing: 8) {
        Button("Open Claude", action: openClaude).buttonStyle(.borderedProminent).controlSize(.small)
        Spacer()
        IconButton(symbol: pinOnTop ? "pin.fill" : "pin", hint: pinOnTop ? "Pinned on top · click to unpin" : "Pin on top of other windows") { pinOnTop.toggle() }
        IconButton(symbol: keepExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                   hint: keepExpanded ? "Stays open · click to let it collapse" : "Keep it open") { keepExpanded.toggle() }
        SyncButton(store: store)
        IconButton(symbol: "menubar.arrow.up.rectangle", hint: "Move to the menu bar") { Prefs.d.set(Placement.menuBar.rawValue, forKey: "placement") }
        IconButton(symbol: "gearshape", hint: "Settings") { Windows.showSettings() }
      }
      .font(.system(size: 13))
    }
    .padding(16)
  }
}
