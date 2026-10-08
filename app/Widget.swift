// The floating Gauge widget: one glass panel per chosen screen, as an edge belt or a floating capsule.
// The belt shows the limits as nested rings and one bead per running chat; hover a bead to peek at that chat.
// Drag it anywhere (it follows the pointer 1:1 and glides into place); hover peeks, click opens fully.
import AppKit
import SwiftUI

enum Placement: String, CaseIterable, Identifiable {
  case menuBar = "Menu bar", floating = "Floating on screen"
  var id: String { rawValue }
}

enum WidgetForm: String, CaseIterable, Identifiable {
  case edge = "Edge belt", capsule = "Floating"
  var id: String { rawValue }
}

enum WidgetShow: String, CaseIterable, Identifiable {
  case withClaude = "When Claude is in use", always = "Always"
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
  var dragging = false
  /// The chat whose bead is hovered: the peek shows that chat instead of the full card.
  var focus: String?
  /// Size multiplier: Settings → Size, or Auto from the screen (bigger on big displays).
  var scale: CGFloat = 1
}

let widgetPanelSize = NSSize(width: 420, height: 820)
func panelSize(_ scale: CGFloat) -> NSSize { NSSize(width: widgetPanelSize.width * scale, height: widgetPanelSize.height * scale) }

enum WidgetSize: String, CaseIterable, Identifiable {
  case auto = "Auto", small = "Small", medium = "Medium", large = "Large", xl = "Extra large"
  var id: String { rawValue }
  /// Auto grows with the display: 1× on a laptop, up to 1.5× on a large monitor.
  func scale(for screen: NSScreen?) -> CGFloat {
    switch self {
    case .auto: min(1.5, max(1, (screen?.frame.height ?? 900) / 1050))
    case .small: 0.9
    case .medium: 1.1
    case .large: 1.3
    case .xl: 1.5
    }
  }
}
let widgetSpring = Animation.spring(response: 0.35, dampingFraction: 1)

final class PassivePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  /// Let it sit flush against any screen edge.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the widget and moves it: a drag on the card is handled here, before SwiftUI sees it,
/// so it works on the first click of an inactive app and never fights a SwiftUI gesture.
final class WidgetHostingView<V: View>: NSHostingView<V> {
  weak var instance: WidgetInstance?
  private var dragged = false
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with e: NSEvent) {
    dragged = false
    window?.orderFrontRegardless() // unpinned, it still comes to the front when you click it
    instance?.pressBegan()
    super.mouseDown(with: e)
  }

  override func mouseDragged(with e: NSEvent) {
    if instance?.dragMoved() == true {
      dragged = true
      return
    }
    super.mouseDragged(with: e)
  }

  override func mouseUp(with e: NSEvent) {
    if dragged {
      dragged = false
      instance?.dragEnded()
      return // SwiftUI never sees this release, so nothing under the pointer counts it as a click
    }
    instance?.pressEnded()
    super.mouseUp(with: e)
  }
}

/// One widget on one screen.
@MainActor final class WidgetInstance {
  var screenID: String
  let model = WidgetModel()
  let panel: PassivePanel
  unowned let controller: WidgetController
  private var hoverSince: Date?
  private var awaySince: Date?
  private var changedAt = Date.distantPast
  /// Union of every frame the card had since it last opened, so a card mid-animation never "loses" the pointer.
  private var stickyRect: CGRect = .null
  private var press: (mouse: NSPoint, origin: NSPoint, handle: Bool)?

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
    let host = WidgetHostingView(rootView: WidgetRoot(store: store, model: model, instance: self))
    panel.contentView = host
    host.instance = self
    if Prefs.keepExpanded { model.expansion = .full }
  }

  var screen: NSScreen? { NSScreen.screens.first { Self.id(of: $0) == screenID } }
  static func id(of s: NSScreen) -> String { "\((s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)" }

  /// "Keep it open" holds the card open: it never collapses, and a full card stays full.
  func set(_ e: Expansion) {
    var target = e
    if e == .collapsed, Prefs.keepExpanded { target = model.expansion == .full ? .full : .peek }
    guard model.expansion != target else { return }
    if target == .full { controller.store.markSeen() }
    changedAt = .now
    if target == .collapsed {
      stickyRect = .null
      model.focus = nil
    }
    withAnimation(widgetSpring) { model.expansion = target }
  }

  func tap() { set(model.expansion == .full ? .collapsed : .full) }

  /// The card's on-screen rect: its layout frame scaled around its anchor (see WidgetRoot's scaleEffect).
  func contentScreenRect() -> CGRect {
    let f = model.contentFrame, s = model.scale
    let ax: CGFloat = model.anchor.horizontal == .leading ? 0 : model.anchor.horizontal == .trailing ? 1 : 0.5
    let ay: CGFloat = model.anchor.vertical == .top ? 0 : model.anchor.vertical == .bottom ? 1 : 0.5
    let w = f.width * s, h = f.height * s
    let minX = f.minX + ax * f.width - ax * w, minY = f.minY + ay * f.height - ay * h
    return CGRect(x: panel.frame.minX + minX, y: panel.frame.maxY - (minY + h), width: w, height: h)
  }

  /// Polled ~12×/s. Open on hover, stay open while the pointer is anywhere on the card.
  func pollHover() {
    guard !model.dragging, panel.isVisible else { return }
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

  // MARK: Drag. Raw mouse events, so the widget tracks the pointer exactly; on release it glides into place.

  func pressBegan() {
    let mouse = NSEvent.mouseLocation
    press = (mouse, panel.frame.origin, isHandle(mouse))
  }

  func pressEnded() { press = nil }

  /// True while this press is moving the widget (past a 4 pt threshold, on a handle).
  func dragMoved() -> Bool {
    guard let p = press, p.handle else { return false }
    let mouse = NSEvent.mouseLocation
    if !model.dragging {
      guard hypot(mouse.x - p.mouse.x, mouse.y - p.mouse.y) > 4 else { return false }
      model.dragging = true
      stickyRect = .null
      panel.level = .floating
    }
    panel.setFrameOrigin(NSPoint(x: p.origin.x + mouse.x - p.mouse.x, y: p.origin.y + mouse.y - p.mouse.y))
    return true
  }

  func dragEnded() {
    press = nil
    guard model.dragging else { return }
    drop(at: NSEvent.mouseLocation)
  }

  /// The whole widget is a handle when collapsed or peeking; a full card is moved by its header.
  private func isHandle(_ mouse: NSPoint) -> Bool {
    let r = contentScreenRect()
    guard r.contains(mouse) else { return false }
    return model.expansion == .collapsed || mouse.y > r.maxY - 52 * model.scale
  }

  /// Near the left or right edge: the belt docks there. Anywhere else: floats.
  private func drop(at mouse: NSPoint) {
    let others = NSScreen.screens.first { $0.frame.contains(mouse) }
    let target = Prefs.screens == "all" ? (screen ?? others) : (others ?? screen)
    guard let target else { model.dragging = false; return }
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
    if Prefs.screens != "all", let i = NSScreen.screens.firstIndex(of: target) {
      screenID = id
      d.set("\(i + 1)", forKey: "widgetScreens")
    }
    model.dragging = false
    if Prefs.form != .capsule { set(.collapsed) }
    place(animated: true)
    controller.settled(after: self)
  }

  /// Moves the panel so the content keeps its place on screen while its anchor changes.
  private func reanchor(_ a: Alignment) {
    guard a != model.anchor else { return }
    let c = contentScreenRect()
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t) { model.anchor = a }
    if c.width > 0 { panel.setFrame(frame(content: c), display: true) }
  }

  private func frame(content c: CGRect) -> NSRect {
    let pad = WidgetRoot.padding, a = model.anchor
    let size = panelSize(model.scale)
    let x = a.horizontal == .leading ? c.minX - pad : a.horizontal == .trailing ? c.maxX + pad - size.width : c.midX - size.width / 2
    let y = a.vertical == .top ? c.maxY + pad - size.height : a.vertical == .bottom ? c.minY - pad : c.midY - size.height / 2
    return NSRect(origin: NSPoint(x: x, y: y), size: size)
  }

  /// Puts the widget where its form and saved position say; `animated` glides it there.
  func place(animated: Bool = false) {
    guard let screen else { return }
    let vis = screen.visibleFrame
    let scale = (WidgetSize(rawValue: Prefs.d.string(forKey: "widgetSize") ?? "") ?? .auto).scale(for: screen)
    if scale != model.scale {
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) { model.scale = scale }
    }
    let raw = model.expansion == .collapsed ? model.contentFrame.size : .zero
    let measured = CGSize(width: raw.width * scale, height: raw.height * scale)
    let anchor: Alignment
    let content: CGRect
    switch Prefs.form {
    case .capsule:
      let size = measured.width > 0 && measured.width < 200 * scale ? measured : CGSize(width: 110 * scale, height: 34 * scale)
      let saved = Prefs.d.array(forKey: "capsule.\(screenID)") as? [Double]
      var c = CGRect(x: saved.map { vis.minX + $0[0] * vis.width } ?? vis.maxX - 12 - size.width,
                     y: saved.map { vis.minY + $0[1] * vis.height } ?? vis.maxY - 12 - size.height,
                     width: size.width, height: size.height)
      c.origin.x = min(max(c.minX, vis.minX + 6), vis.maxX - 6 - size.width)
      c.origin.y = min(max(c.minY, vis.minY + 6), vis.maxY - 6 - size.height)
      let right = c.midX > vis.midX, top = c.midY > vis.midY
      anchor = top ? (right ? .topTrailing : .topLeading) : (right ? .bottomTrailing : .bottomLeading)
      content = c
    case .edge:
      let right = Prefs.side == .right
      let size = measured.width > 0 && measured.width < 90 * scale ? measured : CGSize(width: 66 * scale, height: 120 * scale)
      let f = Prefs.d.object(forKey: "edgeY.\(screenID)") as? Double ?? 0.62
      let cy = min(max(vis.minY + f * vis.height, vis.minY + size.height / 2 + 6), vis.maxY - size.height / 2 - 6)
      // The open card grows down from a belt in the top third, up from one in the bottom third, else both ways.
      let third = (cy - vis.minY) / vis.height
      anchor = Alignment(horizontal: right ? .trailing : .leading, vertical: third > 0.66 ? .top : third < 0.34 ? .bottom : .center)
      content = CGRect(x: right ? vis.maxX - size.width : vis.minX, y: cy - size.height / 2, width: size.width, height: size.height)
    }
    reanchor(anchor)
    let target = frame(content: content)
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.32
        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
    applyLevel()
  }

  func applyLevel() { panel.level = Prefs.pinOnTop ? .floating : .normal }
}

@MainActor final class WidgetController {
  let store: Store
  private(set) var instances: [WidgetInstance] = []
  private var claudeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty
  /// A Claude Code chat anywhere (terminal, an IDE, the desktop app) was active in the last 15 minutes.
  private var chatsActive = false
  private var claudeInUse: Bool { claudeRunning || chatsActive }
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

  private var signature: String {
    let visible = Prefs.placement == .floating && (Prefs.show == .always || claudeInUse)
    let ids = visible ? targetScreens.map(WidgetInstance.id(of:)) : []
    return ids.joined(separator: ",") + "|\(Prefs.form.rawValue)|\(Prefs.side.rawValue)|\(Prefs.d.string(forKey: "widgetSize") ?? "")"
  }

  /// ⌥⌘G: opens the full card on every widget (held open), or closes it.
  func toggleFull() {
    let open = instances.contains { $0.model.expansion == .full }
    instances.forEach { $0.set(open ? .collapsed : .full) }
    instances.forEach { $0.panel.orderFrontRegardless() }
  }

  /// After a drop: the moved widget placed itself (animated); the others follow the new form without a jump.
  func settled(after moved: WidgetInstance) {
    lastSignature = signature
    instances.filter { $0 !== moved }.forEach { $0.place(animated: true) }
  }

  /// Rebuild or update the widgets to match Settings, Claude running, and the connected screens.
  private var applying = false
  func apply(force: Bool = false) {
    guard !applying else { return }
    applying = true
    defer { applying = false }
    let visible = Prefs.placement == .floating && (Prefs.show == .always || claudeInUse)
    let ids = visible ? targetScreens.map(WidgetInstance.id(of:)) : []
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
    activityCheck = activityCheck ?? Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let active = self.store.chats.contains { self.store.nowMs - $0.at < 15 * 60_000 }
        if active != self.chatsActive {
          self.chatsActive = active
          self.apply()
        }
      }
    }
  }
  private var activityCheck: Timer?

  private func startPolling() {
    guard poller == nil else { return }
    poller = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated {
        guard !Prefs.keepExpanded else { return }
        self?.instances.filter { $0.model.expansion == .full }.forEach { $0.set(.collapsed) }
      }
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

private struct ContentFrameKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct WidgetRoot: View {
  static let padding: CGFloat = 24
  let store: Store
  let model: WidgetModel
  let instance: WidgetInstance
  @AppStorage("widgetForm") private var formRaw = WidgetForm.edge.rawValue
  @AppStorage("edgeSide") private var sideRaw = EdgeSide.right.rawValue
  @AppStorage("theme") private var theme = "Sunset"

  private var form: WidgetForm { WidgetForm(rawValue: formRaw) ?? .edge }
  private var unitAnchor: UnitPoint {
    UnitPoint(x: model.anchor.horizontal == .leading ? 0 : model.anchor.horizontal == .trailing ? 1 : 0.5,
              y: model.anchor.vertical == .top ? 0 : model.anchor.vertical == .bottom ? 1 : 0.5)
  }

  var body: some View {
    ZStack(alignment: model.anchor) {
      Color.clear
      card
        .background(GeometryReader { g in Color.clear.preference(key: ContentFrameKey.self, value: g.frame(in: .global)) })
        .scaleEffect(model.scale, anchor: unitAnchor)
        .onHover { model.hovering = $0 }
    }
    .padding(Self.padding)
    .frame(width: panelSize(model.scale).width, height: panelSize(model.scale).height)
    .onPreferenceChange(ContentFrameKey.self) { model.contentFrame = $0 }
    .environment(\.colorScheme, .dark)
    .tint(Palette.accent)
    .id(theme)
  }

  @ViewBuilder private var card: some View {
    Group {
      switch model.expansion {
      case .collapsed: collapsed
      case .peek:
        // Hovering a bead peeks at that chat; hovering anything else shows the full card until the pointer leaves.
        if let id = model.focus, let chat = store.chats.first(where: { $0.id == id }) {
          ChatPeek(chat: chat, store: store).frame(width: 360)
        } else {
          FullCard(store: store, instance: instance).frame(width: 360)
        }
      case .full: FullCard(store: store, instance: instance).frame(width: 360)
      }
    }
    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: unitAnchor)), removal: .opacity))
    .modifier(CardChrome(form: form, side: EdgeSide(rawValue: sideRaw) ?? .right, collapsed: model.expansion == .collapsed, glow: store.glow))
    .contentShape(Rectangle())
    .onTapGesture { if model.expansion != .full { instance.tap() } }
    .animation(widgetSpring, value: model.expansion)
    .animation(widgetSpring, value: model.focus)
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
      AgentBelt(store: store, model: model, vertical: true)
    }
  }
}

/// The belt: big nested limit rings (weekly outside, 5-hour inside), then one named bead per active chat.
/// Hover the rings for limits and pace, a bead for that chat; click a bead to open the chat.
struct AgentBelt: View {
  let store: Store
  let model: WidgetModel
  let vertical: Bool

  var body: some View {
    let chats = Array(store.agentChats.prefix(6))
    let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
    layout {
      MiniRings(five: store.five?.percentUsed, week: store.week?.percentUsed)
        .frame(width: 50, height: 50)
        .onHover { if $0 { model.focus = nil } }
        .accessibilityLabel("5-hour \(Int(store.five?.percentUsed ?? 0)) percent, weekly \(Int(store.week?.percentUsed ?? 0)) percent")
      if !chats.isEmpty {
        Capsule().fill(Palette.accent.opacity(0.35)).frame(width: vertical ? 26 : 1.5, height: vertical ? 1.5 : 26)
        ForEach(chats) { c in
          VStack(spacing: 3) {
            Bead(state: c.liveState(now: store.nowMs), stateAt: c.stateAt, letter: String(c.displayTitle.prefix(1)).uppercased())
              .frame(width: 30, height: 30)
            Text(c.displayTitle)
              .font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
              .lineLimit(2).multilineTextAlignment(.center).frame(width: 54)
          }
          .contentShape(Rectangle())
          .onHover { if $0 { model.focus = c.id } }
          .onTapGesture { openChat(c) }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(c.displayTitle), \(c.liveState(now: store.nowMs).rawValue)")
          .accessibilityAddTraits(.isButton)
        }
      }
    }
    .padding(vertical ? .vertical : .horizontal, 12)
    .padding(vertical ? .horizontal : .vertical, 6)
    .frame(width: vertical ? 66 : nil, height: vertical ? nil : 66)
    .overlay {
      // Over today's budget: a slow red glow around the belt.
      if store.overBudget {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { tl in
          let p = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 2)
          RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hot.opacity(0.4 + 0.5 * p), lineWidth: 2)
            .shadow(color: Palette.hot.opacity(0.6 * p), radius: 8)
        }
        .allowsHitTesting(false)
        .help("Over today's budget")
      }
    }
    .animation(widgetSpring, value: chats.map(\.id))
  }
}

/// Weekly outside (secondary color), 5-hour inside (main color); they turn yellow from 75% and red from 90%.
struct MiniRings: View {
  let five: Double?
  let week: Double?
  var body: some View {
    GeometryReader { g in
      let d = min(g.size.width, g.size.height), lw = d * 0.12
      ZStack {
        ring(week, Palette.secondary, d, lw)
        ring(five, Palette.accent, d - lw * 2.6, lw)
        Text(five.map { "\(Int($0.rounded()))" } ?? "–")
          .font(.system(size: d * 0.24, weight: .bold, design: .rounded).monospacedDigit())
      }
      .frame(width: d, height: d)
    }
  }

  private func ring(_ pct: Double?, _ base: Color, _ d: CGFloat, _ lw: CGFloat) -> some View {
    let p = pct ?? 0
    let color = p >= 90 ? Palette.hot : p >= 75 ? Palette.warn : base
    return ZStack {
      Circle().stroke(color.opacity(0.18), lineWidth: lw)
      Circle().trim(from: 0, to: min(1, max(0.02, p / 100))).stroke(color, style: .init(lineWidth: lw, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: d - lw, height: d - lw)
  }
}

/// One chat, its initial inside: a spinning ring while it works, pulsing orange when it needs you,
/// green with a check for 10 seconds after it finishes, then quiet again.
struct Bead: View {
  let state: ChatState
  let stateAt: Double
  let letter: String
  var body: some View {
    let justDone = state == .done && Date().timeIntervalSince1970 * 1000 - stateAt < 10_000
    TimelineView(.animation(paused: (state != .working && state != .waiting && !justDone) || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { tl in
      let t = tl.date.timeIntervalSinceReferenceDate
      let done = state == .done && tl.date.timeIntervalSince1970 * 1000 - stateAt < 10_000
      ZStack {
        switch state {
        case .working:
          Circle().fill(Palette.accent.opacity(0.14))
          Circle().stroke(Palette.accent.opacity(0.25), lineWidth: 3)
          Circle().trim(from: 0, to: 0.28).stroke(Palette.accent, style: .init(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
          Text(letter).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent)
        case .waiting:
          Circle().fill(Palette.waiting).scaleEffect(0.86 + 0.14 * (0.5 + 0.5 * sin(t * 4)))
          Text("!").font(.system(size: 14, weight: .black, design: .rounded)).foregroundStyle(.black)
        case .done where done:
          Circle().fill(Palette.done)
          Image(systemName: "checkmark").font(.system(size: 12, weight: .black)).foregroundStyle(.black)
        default:
          Circle().fill(.white.opacity(0.06))
          Circle().stroke(.white.opacity(0.22), lineWidth: 1.5)
          Text(letter).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Glass everywhere; the edge belt is square on the side that touches the screen edge.
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

/// Hovering a bead: that chat. Waiting: its question with quick replies. Running: its last steps, live.
struct ChatPeek: View {
  let chat: Chat
  let store: Store
  @State private var copied: String?

  var body: some View {
    let s = chat.liveState(now: store.nowMs)
    let act = store.activity[chat.id] ?? Activity()
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 7) {
        stateIcon(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.state(s))
        Text(chat.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2)
        Spacer(minLength: 4)
        ModelChip(store: store, chat: chat)
      }
      switch s {
      case .waiting:
        Text(chat.question.isEmpty ? "Claude is waiting for you" : chat.question)
          .font(.system(size: 11.5)).foregroundStyle(Palette.waiting).fixedSize(horizontal: false, vertical: true)
        if !act.choices.isEmpty {
          FlowChips(items: act.choices) { choice in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(choice, forType: .string)
            copied = choice
            openChat(chat)
          }
          Text(copied == nil ? "Pick an answer: it's copied and the chat opens, ready to paste." : "Copied “\(copied!)”. Paste it in the chat.")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
      case .working:
        ProgressLine(state: s, activity: act)
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(act.recent.enumerated()), id: \.offset) { i, step in
            HStack(spacing: 6) {
              Circle().fill(i == act.recent.count - 1 ? Palette.accent : .white.opacity(0.3)).frame(width: 5, height: 5)
              Text(step).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(i == act.recent.count - 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .animation(widgetSpring, value: act.recent)
      default:
        Text(s == .done ? "Finished \(Format.ago(chat.stateAt)) ago" : "Idle").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      HStack {
        Text("Click the bead to open this chat").font(.system(size: 10)).foregroundStyle(.tertiary)
        Spacer()
        MoneyPair(today: store.todaySpend(chat), total: store.totalSpend(chat))
      }
    }
    .padding(14)
  }
}

/// Answer buttons that wrap onto as many lines as they need.
struct FlowChips: View {
  let items: [String]
  let pick: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(items, id: \.self) { item in
        Button { pick(item) } label: {
          Text(item).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.waiting.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.waiting.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
    }
  }
}

struct FullCard: View {
  let store: Store
  let instance: WidgetInstance
  @AppStorage("pinOnTop") private var pinOnTop = true
  @AppStorage("keepExpanded") private var keepExpanded = false
  @AppStorage("tab") private var tab = GaugeTab.overview.rawValue

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Header(store: store) {
        Button { instance.set(.collapsed) } label: {
          Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10, weight: .bold))
            .foregroundStyle(Palette.accent)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Palette.accent.opacity(0.16)))
            .overlay(Circle().strokeBorder(Palette.accent.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain).help("Collapse").accessibilityLabel("Collapse")
      }
      TabSwitch(tab: $tab, agents: store.agentChats.count)
      if tab == GaugeTab.agents.rawValue {
        AgentsView(store: store)
      } else if tab == GaugeTab.projects.rawValue {
        ProjectsView(store: store)
      } else {
        LimitsView(store: store, ringSize: 58)
        SpendChart(store: store, days: 30)
        ChatsView(store: store)
      }
      GaugeToolbar {
        IconButton(symbol: pinOnTop ? "pin.fill" : "pin", hint: pinOnTop ? "Pinned on top · click to unpin" : "Pin on top of other windows") { pinOnTop.toggle() }
        IconButton(symbol: keepExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                   hint: keepExpanded ? "Stays open · click to let it collapse" : "Keep it open") { keepExpanded.toggle() }
        SyncButton(store: store)
        IconButton(symbol: "menubar.arrow.up.rectangle", hint: "Move to the menu bar") { Prefs.d.set(Placement.menuBar.rawValue, forKey: "placement") }
        IconButton(symbol: "gearshape", hint: "Settings") { Windows.showSettings() }
      }
    }
    .padding(14)
  }
}
