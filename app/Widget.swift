// The floating Gauge widget: one glass panel per chosen screen, as an edge belt, a Dock shelf or a floating capsule.
// The belt shows the limits as nested rings and one bead per running chat; hover a bead to peek at that chat.
// Drag it anywhere (it follows the pointer 1:1 and glides into place); hover peeks, click opens fully.
import AppKit
import SwiftUI

enum Placement: String, CaseIterable, Identifiable {
  case menuBar = "Menu bar", floating = "Floating on screen"
  var id: String { rawValue }
}

enum WidgetForm: String, CaseIterable, Identifiable {
  case edge = "Edge belt", dock = "Dock shelf", capsule = "Floating"
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
  /// The chat whose bead is hovered: the peek shows that chat instead of the overview.
  var focus: String?
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
    panel.contentView = FirstClickHostingView(rootView: WidgetRoot(store: store, model: model, instance: self))
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

  func contentScreenRect() -> CGRect {
    let f = model.contentFrame
    return CGRect(x: panel.frame.minX + f.minX, y: panel.frame.maxY - f.maxY, width: f.width, height: f.height)
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

  /// Returns nil for the events the drag consumes.
  func handleMouse(_ e: NSEvent) -> NSEvent? {
    let mouse = NSEvent.mouseLocation
    switch e.type {
    case .leftMouseDown:
      press = (mouse, panel.frame.origin, isHandle(mouse))
      return e
    case .leftMouseDragged:
      guard let p = press, p.handle else { return e }
      if !model.dragging {
        guard hypot(mouse.x - p.mouse.x, mouse.y - p.mouse.y) > 4 else { return e }
        model.dragging = true
        stickyRect = .null
        panel.level = .floating
      }
      panel.setFrameOrigin(NSPoint(x: p.origin.x + mouse.x - p.mouse.x, y: p.origin.y + mouse.y - p.mouse.y))
      return nil
    case .leftMouseUp:
      press = nil
      guard model.dragging else { return e }
      drop(at: mouse)
      return nil
    default:
      return e
    }
  }

  /// The whole widget is a handle when collapsed or peeking; a full card is moved by its header.
  private func isHandle(_ mouse: NSPoint) -> Bool {
    let r = contentScreenRect()
    guard r.contains(mouse) else { return false }
    return model.expansion != .full || mouse.y > r.maxY - 52
  }

  /// Near the left or right edge: the belt docks there. Near the bottom: the Dock shelf. Anywhere else: floats.
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
    } else if c.minY - vis.minY < 60 {
      d.set((c.midX - vis.minX) / vis.width, forKey: "dockX.\(id)")
      d.set(WidgetForm.dock.rawValue, forKey: "widgetForm")
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
    let x = a.horizontal == .leading ? c.minX - pad : a.horizontal == .trailing ? c.maxX + pad - widgetPanelSize.width : c.midX - widgetPanelSize.width / 2
    let y = a.vertical == .top ? c.maxY + pad - widgetPanelSize.height : a.vertical == .bottom ? c.minY - pad : c.midY - widgetPanelSize.height / 2
    return NSRect(origin: NSPoint(x: x, y: y), size: widgetPanelSize)
  }

  /// Puts the widget where its form and saved position say; `animated` glides it there.
  func place(animated: Bool = false) {
    guard let screen else { return }
    let vis = screen.visibleFrame
    let measured = model.expansion == .collapsed ? model.contentFrame.size : .zero
    let anchor: Alignment
    let content: CGRect
    switch Prefs.form {
    case .capsule:
      let size = measured.width > 0 && measured.width < 200 ? measured : CGSize(width: 110, height: 34)
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
      let size = measured.width > 0 && measured.width < 60 ? measured : CGSize(width: 36, height: 80)
      let f = Prefs.d.object(forKey: "edgeY.\(screenID)") as? Double ?? 0.62
      let cy = min(max(vis.minY + f * vis.height, vis.minY + size.height / 2 + 6), vis.maxY - size.height / 2 - 6)
      // The open card grows down from a belt in the top third, up from one in the bottom third, else both ways.
      let third = (cy - vis.minY) / vis.height
      anchor = Alignment(horizontal: right ? .trailing : .leading, vertical: third > 0.66 ? .top : third < 0.34 ? .bottom : .center)
      content = CGRect(x: right ? vis.maxX - size.width : vis.minX, y: cy - size.height / 2, width: size.width, height: size.height)
    case .dock:
      let size = measured.height > 0 && measured.height < 60 ? measured : CGSize(width: 120, height: 36)
      let f = Prefs.d.object(forKey: "dockX.\(screenID)") as? Double ?? 0.5
      let cx = min(max(vis.minX + f * vis.width, vis.minX + size.width / 2 + 6), vis.maxX - size.width / 2 - 6)
      anchor = .bottom
      content = CGRect(x: cx - size.width / 2, y: vis.minY + 6, width: size.width, height: size.height)
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
  private var dragMonitor: Any?
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
    return ids.joined(separator: ",") + "|\(Prefs.form.rawValue)|\(Prefs.side.rawValue)"
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
    dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
      MainActor.assumeIsolated {
        guard let inst = self?.instances.first(where: { $0.panel === e.window }) else { return e }
        return inst.handleMouse(e)
      }
    }
  }

  private func stopPolling() {
    poller?.invalidate()
    poller = nil
    for m in [clickMonitor, dragMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
    clickMonitor = nil
    dragMonitor = nil
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
  @AppStorage("theme") private var theme = "Ocean"

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
      case .peek:
        if let id = model.focus, let chat = store.chats.first(where: { $0.id == id }) {
          ChatPeek(chat: chat, store: store).frame(width: 300)
        } else {
          PeekCard(store: store).frame(width: 300)
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
    case .dock:
      AgentBelt(store: store, model: model, vertical: false)
    }
  }
}

/// The belt: nested limit rings, then one bead per running chat. Hover the rings for limits and pace,
/// a bead for that chat; click a bead to open the chat.
struct AgentBelt: View {
  let store: Store
  let model: WidgetModel
  let vertical: Bool

  var body: some View {
    let chats = Array(store.agentChats.prefix(6))
    let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    layout {
      MiniRings(five: store.five?.percentUsed ?? 0, week: store.week?.percentUsed ?? 0, glow: store.glow)
        .frame(width: 24, height: 24)
        .onHover { if $0 { model.focus = nil } }
        .help("5-hour \(Int(store.five?.percentUsed ?? 0))% · weekly \(Int(store.week?.percentUsed ?? 0))%")
      if !chats.isEmpty {
        Capsule().fill(.white.opacity(0.15)).frame(width: vertical ? 16 : 1, height: vertical ? 1 : 16)
        ForEach(chats) { c in
          Bead(state: c.liveState(now: store.nowMs))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { if $0 { model.focus = c.id } }
            .onTapGesture { openChat(c) }
            .accessibilityLabel("\(c.displayTitle), \(c.liveState(now: store.nowMs).rawValue)")
            .accessibilityAddTraits(.isButton)
        }
      }
    }
    .padding(vertical ? .vertical : .horizontal, 10)
    .frame(width: vertical ? 36 : nil, height: vertical ? nil : 36)
    .animation(widgetSpring, value: chats.map(\.id))
  }
}

/// Weekly outside, 5-hour inside, the state dot in the middle.
struct MiniRings: View {
  let five: Double
  let week: Double
  let glow: Glow
  var body: some View {
    ZStack {
      ring(week, 24)
      ring(five, 15)
      Circle().fill(glow == .idle || glow == .hot ? Color.white.opacity(0.8) : glow.color).frame(width: 5, height: 5)
    }
  }

  private func ring(_ pct: Double, _ d: CGFloat) -> some View {
    ZStack {
      Circle().stroke(.white.opacity(0.14), lineWidth: 3)
      Circle().trim(from: 0, to: min(1, max(0.02, pct / 100))).stroke(Palette.level(pct), style: .init(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: d - 3, height: d - 3)
  }
}

/// One running chat: spinning while it works, pulsing orange when it needs you, a green check when done.
struct Bead: View {
  let state: ChatState
  var body: some View {
    let tint = Palette.state(state)
    TimelineView(.animation(paused: state != .working && state != .waiting || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { tl in
      let t = tl.date.timeIntervalSinceReferenceDate
      ZStack {
        switch state {
        case .working:
          Circle().stroke(tint.opacity(0.25), lineWidth: 2.5)
          Circle().trim(from: 0, to: 0.3).stroke(tint, style: .init(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
        case .waiting:
          Circle().fill(tint).scaleEffect(0.8 + 0.2 * (0.5 + 0.5 * sin(t * 4)))
          Text("!").font(.system(size: 10, weight: .black)).foregroundStyle(.black)
        case .done:
          Circle().fill(tint.opacity(0.9))
          Image(systemName: "checkmark").font(.system(size: 8, weight: .black)).foregroundStyle(.black)
        case .idle:
          Circle().stroke(tint, lineWidth: 2)
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
    case .dock:
      content.glassCard(radius: collapsed ? 18 : 20, tint: tint)
    case .capsule:
      content.glassCard(radius: collapsed ? 18 : 20, tint: tint)
    }
  }
}

/// Hovering the rings or the capsule: limits with their pace forecast, and the chat that matters most.
struct PeekCard: View {
  let store: Store
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
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
      VStack(alignment: .leading, spacing: 3) {
        ForEach([store.five, store.week].compactMap { $0 }, id: \.kind) { l in
          if let f = l.forecast() {
            Label(f.text, systemImage: f.risky ? "exclamationmark.triangle.fill" : "speedometer")
              .font(.system(size: 10.5)).foregroundStyle(f.risky ? Palette.hot : .secondary)
          }
        }
      }
      if let c = store.rankedChats.first { ChatRow(chat: c, store: store, highlight: true).padding(.horizontal, -8) }
      Text("Click for details").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
    }
    .padding(14)
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
        Text(chat.displayTitle).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
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
              Text(step).font(.system(size: 11)).lineLimit(1)
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
