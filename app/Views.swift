// Shared Gauge views: header, limits (rings or bars), cost tiles, spend chart, chats (now card + rows).
import Charts
import SwiftUI

enum LimitsStyle: String, CaseIterable, Identifiable {
  case rings = "Rings", bars = "Bars", marker = "Bars + time", nested = "Nested ring"
  var id: String { rawValue }
}

struct SectionLabel: View {
  let text: String
  var body: some View {
    Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
  }
}

struct StateBadge: View {
  let glow: Glow
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: glow.symbol).font(.system(size: 9, weight: .bold))
        .symbolEffect(.pulse, isActive: glow.animates)
      Text(glow == .idle ? "Idle" : glow.label).font(.system(size: 10, weight: .semibold))
    }
    .foregroundStyle(glow == .idle ? Color.secondary : glow.color)
    .padding(.horizontal, 7).padding(.vertical, 3)
    .background(Capsule().fill((glow == .idle ? Color.white : glow.color).opacity(0.12)))
  }
}

struct Header<Trailing: View>: View {
  let store: Store
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      LiveMark(store: store).frame(width: 30, height: 30)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text("Claude Gauge").font(.system(size: 14, weight: .semibold))
          StateBadge(glow: store.glow)
        }
        Text(Greeting.now() + (store.updatedAt > 0 ? " · updated \(Format.ago(store.updatedAt))" : ""))
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      trailing
    }
  }
}

struct LimitRing: View {
  let title: String
  let limit: Limit?
  var size: CGFloat = 64
  var body: some View {
    let pct = limit?.percentUsed ?? 0
    VStack(spacing: 6) {
      ZStack {
        Circle().stroke(.white.opacity(0.08), lineWidth: size * 0.09)
        Circle()
          .trim(from: 0, to: min(1, pct / 100))
          .stroke(Palette.level(pct), style: .init(lineWidth: size * 0.09, lineCap: .round))
          .rotationEffect(.degrees(-90))
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text(limit == nil ? "–" : "\(Int(pct.rounded()))").font(.system(size: size * 0.3, weight: .semibold, design: .rounded).monospacedDigit())
          Text("%").font(.system(size: size * 0.14, weight: .medium)).foregroundStyle(.secondary)
        }
      }
      .frame(width: size, height: size)
      VStack(spacing: 1) {
        Text(title).font(.system(size: 11, weight: .medium))
        Text(limit?.resetDate.map { "resets in \(Format.until($0))" } ?? " ").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// One thin line: label, bar, percent, time until it resets.
struct LimitBar: View {
  let title: String
  let limit: Limit?
  /// Draws a tick at how much of the window has already passed: usage ahead of the tick burns too fast.
  var marker = false
  var body: some View {
    let pct = limit?.percentUsed ?? 0
    HStack(spacing: 8) {
      Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.1))
          Capsule().fill(Palette.level(pct)).frame(width: max(3, g.size.width * min(1, pct / 100)))
          if marker, let f = limit?.elapsedFraction {
            RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 2, height: 10).offset(x: g.size.width * f - 1)
          }
        }
        .frame(maxHeight: .infinity)
      }
      .frame(height: marker ? 10 : 4)
      Text(limit == nil ? "–" : "\(Int(pct.rounded()))%")
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Palette.level(pct))
        .frame(width: 34, alignment: .trailing)
      Text(limit?.resetDate.map { "resets in \(Format.until($0))" } ?? "")
        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
        .frame(width: 92, alignment: .trailing)
    }
    .frame(height: 16)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(Int(pct.rounded())) percent used, resets in \(Format.until(limit?.resetDate))")
  }
}

struct LimitsView: View {
  let store: Store
  var ringSize: CGFloat = 64
  @AppStorage("limitsStyle") private var style = LimitsStyle.rings.rawValue

  var body: some View {
    VStack(spacing: 8) {
      switch LimitsStyle(rawValue: style) ?? .rings {
      case .rings:
        HStack(spacing: 32) {
          LimitRing(title: "5-hour", limit: store.five, size: ringSize)
          LimitRing(title: "Weekly", limit: store.week, size: ringSize)
        }
        .frame(maxWidth: .infinity)
      case .bars, .marker:
        let marker = style == LimitsStyle.marker.rawValue
        VStack(spacing: 6) {
          LimitBar(title: "5-hour", limit: store.five, marker: marker)
          LimitBar(title: "Weekly", limit: store.week, marker: marker)
        }
      case .nested:
        NestedRings(five: store.five, week: store.week, size: ringSize * 1.25)
      }
      if let m = store.paceMinutesLeft, m < 300 {
        Label("At this pace the 5-hour limit runs out in \(Format.minutes(m))", systemImage: "speedometer")
          .font(.system(size: 10)).foregroundStyle(m < 45 ? Palette.hot : .secondary)
      }
    }
  }
}

/// One ring, two tracks: weekly outside, 5-hour inside, with a legend beside it.
struct NestedRings: View {
  let five: Limit?
  let week: Limit?
  var size: CGFloat = 80
  var body: some View {
    HStack(spacing: 18) {
      ZStack {
        track(week, diameter: size, width: size * 0.09)
        track(five, diameter: size * 0.72, width: size * 0.09)
        Text(five == nil ? "–" : "\(Int((five?.percentUsed ?? 0).rounded()))%")
          .font(.system(size: size * 0.18, weight: .semibold, design: .rounded).monospacedDigit())
      }
      .frame(width: size, height: size)
      VStack(alignment: .leading, spacing: 8) {
        legend("5-hour", five, inner: true)
        legend("Weekly", week, inner: false)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private func track(_ l: Limit?, diameter: CGFloat, width: CGFloat) -> some View {
    let pct = l?.percentUsed ?? 0
    return ZStack {
      Circle().stroke(.white.opacity(0.08), lineWidth: width)
      Circle().trim(from: 0, to: min(1, pct / 100))
        .stroke(Palette.level(pct), style: .init(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90))
    }
    .frame(width: diameter, height: diameter)
  }

  private func legend(_ title: String, _ l: Limit?, inner: Bool) -> some View {
    let pct = l?.percentUsed ?? 0
    return VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        Text(inner ? "Inner" : "Outer").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        Text(title).font(.system(size: 11, weight: .medium))
        Text(l == nil ? "–" : "\(Int(pct.rounded()))%").font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(Palette.level(pct))
      }
      Text(l?.resetDate.map { "resets in \(Format.until($0))" } ?? " ").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
    }
  }
}

struct CostTiles: View {
  let store: Store
  var body: some View {
    HStack(spacing: 6) {
      tile("Today", store.today, "sun.max.fill", Palette.secondary)
      tile("Week", store.thisWeek, "calendar", Palette.accent)
      tile("Month", store.thisMonth, "chart.bar.fill", Color(red: 0.72, green: 0.6, blue: 1))
    }
  }
  private func tile(_ label: String, _ v: Double, _ symbol: String, _ tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(label, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(tint).lineLimit(1)
      Text(Format.money(v)).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 9).padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    .accessibilityElement(children: .combine)
  }
}

struct SpendChart: View {
  let store: Store
  var days = 30
  var height: CGFloat = 92
  /// Today · Week · Month on one line as the chart's title.
  var showTotals = true
  @State private var selected: Date?

  /// Label and amount side by side when they fit, else stacked; never wrapped mid-number.
  private func total(_ label: String, _ v: Double, _ tint: Color) -> some View {
    let name = Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
    let value = Text(Format.money(v)).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 5) { name; value }.fixedSize()
      VStack(alignment: .leading, spacing: 0) { name; value }.fixedSize()
      VStack(alignment: .leading, spacing: 0) { name; value.minimumScaleFactor(0.6).lineLimit(1) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  var body: some View {
    let data = store.series(days)
    let pick = selected.flatMap { s in data.first { Calendar.current.isDate($0.date, inSameDayAs: s) } }
    VStack(alignment: .leading, spacing: 6) {
      if showTotals {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          total("Today", store.today, Palette.secondary)
          total("Week", store.thisWeek, .primary)
          total("Month", store.thisMonth, .primary)
        }
      } else {
        SectionLabel(text: "\(days)-day spend")
      }
      Chart(data) { d in
        BarMark(x: .value("Day", d.date, unit: .day), y: .value("USD", d.usd), width: .ratio(0.7))
          .foregroundStyle(Calendar.current.isDateInToday(d.date) || pick?.date == d.date ? Palette.chart : Palette.chart.opacity(0.42))
          .cornerRadius(2)
      }
      .chartXSelection(value: $selected)
      .overlay(alignment: .topLeading) {
        if let pick {
          Text("\(pick.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(Format.money(pick.usd))")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color(white: 0.18)))
            .allowsHitTesting(false)
        }
      }
      .chartYAxis {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.white.opacity(0.12))
          AxisValueLabel { if let x = v.as(Double.self) { Text(Format.axisMoney(x)).font(.system(size: 9).monospacedDigit()) } }
        }
      }
      .chartXAxis {
        AxisMarks(values: .stride(by: .day, count: days > 14 ? 7 : 2)) { _ in
          AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 9))
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: height)
    }
    .frame(maxWidth: .infinity)
  }
}

@ViewBuilder func stateIcon(_ s: ChatState) -> some View {
  switch s {
  case .waiting: Image(systemName: "exclamationmark.bubble.fill").symbolEffect(.pulse)
  case .working: Image(systemName: "rays").symbolEffect(.pulse)
  case .done: Image(systemName: "checkmark.circle.fill")
  case .idle: Image(systemName: "moon.zzz.fill")
  }
}

enum MoneyColumns {
  static let today: CGFloat = 52
  static let total: CGFloat = 58
}

/// "today | total" for one chat, aligned with the header above the rows.
struct MoneyPair: View {
  let today: Double
  let total: Double
  var body: some View {
    HStack(spacing: 5) {
      Text(Format.money(today)).foregroundStyle(today > 0 ? AnyShapeStyle(Palette.secondary) : AnyShapeStyle(.tertiary))
        .frame(width: MoneyColumns.today, alignment: .trailing)
      Text("|").foregroundStyle(.quaternary)
      Text(Format.money(total)).foregroundStyle(.primary).frame(width: MoneyColumns.total, alignment: .trailing)
    }
    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
    .lineLimit(1).minimumScaleFactor(0.8)
  }
}

/// One line per chat: state, live title, today | total. Click opens it in Claude;
/// drag left (or right-click) to pin or hide it.
struct ChatRow: View {
  let chat: Chat
  let store: Store
  var highlight = false
  /// Vertical drag to reorder: called with the offset while dragging, and once with `ended: true`.
  var reorder: ((CGFloat, _ ended: Bool) -> Void)?
  @State private var hover = false
  @State private var axis: Axis?
  @State private var dx: CGFloat = 0
  @State private var dragBase: CGFloat?
  private let reveal: CGFloat = -80

  var body: some View {
    let s = chat.liveState(now: store.nowMs)
    let tint = Palette.state(s)
    let pinned = store.pinned.contains(chat.id)
    ZStack(alignment: .trailing) {
      HStack(spacing: 4) {
        action(pinned ? "pin.slash.fill" : "pin.fill", pinned ? "Unpin" : "Pin", Palette.accent) { store.togglePin(chat) }
        action("eye.slash.fill", "Hide", Color(white: 0.42)) { store.hide(chat) }
      }
      .opacity(dx < -8 ? 1 : 0)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          stateIcon(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
          Text(chat.displayTitle).font(.system(size: 12, weight: highlight ? .semibold : .medium))
            .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
            .help(chat.displayTitle)
          if pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary) }
          Spacer(minLength: 6)
          MoneyPair(today: store.todaySpend(chat), total: store.totalSpend(chat))
        }
        if s == .waiting, !chat.question.isEmpty {
          Text(chat.question).font(.system(size: 11)).foregroundStyle(tint).lineLimit(1).padding(.leading, 22)
        }
      }
      .padding(.vertical, 6).padding(.horizontal, 8)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(highlight ? tint.opacity(hover ? 0.18 : 0.12) : .white.opacity(hover ? 0.07 : 0)))
      .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(highlight ? tint.opacity(0.3) : .clear, lineWidth: 1))
      .background(Color(white: 0.11).opacity(dx < 0 ? 1 : 0).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous)))
      .contentShape(Rectangle())
      .offset(x: dx)
      .onTapGesture { dx == 0 ? openChat(chat) : withAnimation(widgetSpring) { dx = 0 } }
      .highPriorityGesture(DragGesture(minimumDistance: 6)
        .onChanged { v in
          if axis == nil { axis = abs(v.translation.height) > abs(v.translation.width) && reorder != nil ? .vertical : .horizontal }
          if axis == .vertical { reorder?(v.translation.height, false); return }
          if dragBase == nil { dragBase = dx }
          dx = min(0, max(reveal - 24, (dragBase ?? 0) + v.translation.width))
        }
        .onEnded { v in
          defer { axis = nil }
          if axis == .vertical { reorder?(v.translation.height, true); return }
          dragBase = nil
          withAnimation(widgetSpring) { dx = dx < reveal / 2 ? reveal : 0 }
        })
    }
    .onHover { hover = $0 }
    .contextMenu {
      Button("Open in Claude") { openChat(chat) }
      Button(pinned ? "Unpin" : "Pin") { store.togglePin(chat) }
      Button("Hide until it's active again") { store.hide(chat) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(chat.displayTitle), \(s.rawValue), today \(Format.money(store.todaySpend(chat))), total \(Format.money(store.totalSpend(chat)))")
    .accessibilityAction(named: pinned ? "Unpin" : "Pin") { store.togglePin(chat) }
    .accessibilityAction(named: "Hide") { store.hide(chat) }
  }

  private func action(_ symbol: String, _ label: String, _ color: Color, _ run: @escaping () -> Void) -> some View {
    Button {
      withAnimation(widgetSpring) {
        run()
        dx = 0
      }
    } label: {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        .frame(width: 36, height: 26).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
    }
    .buttonStyle(.plain).accessibilityLabel(label)
  }
}

/// The most relevant chat highlighted on top, then the next ones (pinned first). Drag a row up or down to reorder.
struct ChatsView: View {
  let store: Store
  var rows = 2
  @State private var dragging: String?
  @State private var dy: CGFloat = 0
  private let step: CGFloat = 34

  var body: some View {
    let ordered = store.rankedChats
    let rest = ordered.dropFirst()
    let visible = Array(ordered.prefix(1)) + Array(rest.prefix(max(rows, rest.filter { store.pinned.contains($0.id) }.count)))
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        SectionLabel(text: "Chats")
        Spacer()
        Group {
          Text("TODAY").frame(width: MoneyColumns.today, alignment: .trailing)
          Text("|").foregroundStyle(.quaternary)
          Text("TOTAL").frame(width: MoneyColumns.total, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 8).padding(.bottom, 2)
      if visible.isEmpty {
        Text("Chats appear here as soon as you send a message in Claude Code.")
          .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
      }
      ForEach(Array(visible.enumerated()), id: \.element.id) { i, chat in
        ChatRow(chat: chat, store: store, highlight: i == 0 && chat.liveState(now: store.nowMs) != .idle) { offset, ended in
          if ended { drop(chat, at: i, offset: offset, visible: visible, all: ordered) } else { dragging = chat.id; dy = offset }
        }
        .offset(y: dragging == chat.id ? dy : 0)
        .zIndex(dragging == chat.id ? 1 : 0)
        .shadow(color: .black.opacity(dragging == chat.id ? 0.4 : 0), radius: 8, y: 3)
      }
    }
    .padding(.horizontal, -8)
  }

  private func drop(_ chat: Chat, at i: Int, offset: CGFloat, visible: [Chat], all: [Chat]) {
    let target = min(max(0, i + Int((offset / step).rounded())), visible.count - 1)
    withAnimation(widgetSpring) {
      if target < i {
        store.move(chat.id, before: visible[target].id)
      } else if target > i {
        let after = all.firstIndex { $0.id == visible[target].id }.map { $0 + 1 } ?? all.endIndex
        store.move(chat.id, before: after < all.count ? all[after].id : nil)
      }
      dragging = nil
      dy = 0
    }
  }
}

extension Store {
  /// Needs input first, then pinned chats, then the rest. Within a group: the user's own order (drag to reorder);
  /// chats not placed yet come first, running before finished before idle, newest first.
  var rankedChats: [Chat] {
    let now = nowMs
    let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    func group(_ c: Chat) -> Int { c.liveState(now: now) == .waiting ? 0 : pinned.contains(c.id) ? 1 : 2 }
    func activity(_ c: Chat) -> Int {
      switch c.liveState(now: now) {
      case .waiting: 3
      case .working: 2
      case .done: 1
      case .idle: 0
      }
    }
    return chats.filter { !isHidden($0) }.sorted { a, b in
      if group(a) != group(b) { return group(a) < group(b) }
      switch (position[a.id], position[b.id]) {
      case let (x?, y?): return x < y
      case (nil, _?): return true
      case (_?, nil): return false
      case (nil, nil): return activity(a) != activity(b) ? activity(a) > activity(b) : a.at > b.at
      }
    }
  }
}

/// Icon button with a name that appears on hover (system tooltips don't show on a panel that never becomes key).
struct IconButton: View {
  let symbol: String
  let hint: String
  let action: () -> Void
  @State private var hover = false
  @State private var showHint = false

  var body: some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
      .buttonStyle(.plain)
      .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .onHover { h in
        hover = h
        withAnimation(.easeOut(duration: 0.15).delay(h ? 0.3 : 0)) { showHint = h }
      }
      .overlay(alignment: .topTrailing) {
        if showHint {
          Text(hint).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color(white: 0.18)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .offset(y: -26)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
      }
      .zIndex(showHint ? 1 : 0)
      .accessibilityLabel(hint)
  }
}

/// Glass card background; solid when Reduce Transparency is on (system or setting).
struct GlassCard: ViewModifier {
  var corners: RectangleCornerRadii
  var tint: Color = .clear
  @AppStorage("solidGlass") private var solid = false
  func body(content: Content) -> some View {
    let reduce = solid || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    let shape = UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
    content
      .background { shape.fill(reduce ? AnyShapeStyle(Color(white: 0.11)) : AnyShapeStyle(.regularMaterial)) }
      .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1) }
      .overlay { shape.strokeBorder(tint.opacity(0.55), lineWidth: 1) }
      .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
      .shadow(color: tint.opacity(0.3), radius: 10)
  }
}

extension RectangleCornerRadii {
  static func all(_ r: CGFloat) -> Self { .init(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r) }
}

extension View {
  func glassCard(radius: CGFloat = 18, tint: Color = .clear) -> some View { modifier(GlassCard(corners: .all(radius), tint: tint)) }
  func glassCard(corners: RectangleCornerRadii, tint: Color = .clear) -> some View { modifier(GlassCard(corners: corners, tint: tint)) }
}
