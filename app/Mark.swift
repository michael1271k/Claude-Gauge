// The Gauge mark in three styles (ring + sparkle, needle, battery), filled by 5-hour usage
// and animated by Claude's state: running moves, needs input pulses orange, done flashes a check.
import AppKit
import SwiftUI

enum IconStyle: String, CaseIterable, Identifiable {
  case ring = "Ring", fill = "Fill", nested = "Nested", bars = "Twin bars"
  var id: String { rawValue }
  var detail: String {
    switch self {
    case .ring: "Sparkle inside a ring that fills with 5-hour use"
    case .fill: "The sparkle itself fills up like a glass"
    case .nested: "Weekly outside, 5-hour inside"
    case .bars: "5-hour and weekly side by side"
    }
  }
}

struct GaugeMark: View {
  var style: IconStyle = .ring
  var glow: Glow
  /// 5-hour usage, 0...100.
  var pct: Double
  /// Weekly usage, 0...100 (nested and twin bars).
  var week: Double = 0
  var time: Double = 0
  var rippleAge: Double = .infinity
  var still = false

  var body: some View {
    Canvas { ctx, size in
      let s = min(size.width, size.height)
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      let fill = Palette.level(pct)
      let stateColor = glow == .idle || glow == .hot ? Color.white : glow.color
      let moving = !still
      let breath = moving && glow == .waiting ? 0.5 + 0.5 * sin(time * 4) : 1
      let checking = moving && rippleAge < 1.4
      let working = glow == .working && moving
      let lw = max(1.4, s * 0.11)
      let p = min(1, max(0, pct / 100)), w = min(1, max(0, week / 100))

      switch style {
      case .ring:
        let r = s / 2 - lw / 2
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.22)), lineWidth: lw)
        ctx.stroke(arc(c, r, 0, max(p, 0.02)), with: .color(fill), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        if working { ctx.stroke(arc(c, r, time * 0.83, time * 0.83 + 0.2), with: .color(Palette.accent), style: StrokeStyle(lineWidth: lw, lineCap: .round)) }
        if checking {
          ctx.stroke(check(in: c, size: s * 0.42), with: .color(Palette.done), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        } else {
          ctx.fill(sparkle(at: c, radius: s * 0.24), with: .color(stateColor.opacity(glow == .waiting ? 0.55 + 0.45 * breath : 1)))
        }

      case .fill:
        // The sparkle is a glass: it fills from the bottom with 5-hour use; a wave runs across it while Claude works.
        let shape = sparkle(at: c, radius: s * 0.5, waist: 0.36)
        let box = shape.boundingRect
        let level = box.maxY - box.height * max(p, 0.04)
        ctx.drawLayer { l in
          l.clip(to: shape)
          var liquid = Path()
          liquid.move(to: CGPoint(x: box.minX, y: box.maxY))
          let amp = working ? s * 0.05 : 0
          for i in 0...12 {
            let x = box.minX + box.width * CGFloat(i) / 12
            liquid.addLine(to: CGPoint(x: x, y: level + amp * sin(Double(i) / 12 * 2 * .pi * 1.5 + time * 6)))
          }
          liquid.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
          liquid.closeSubpath()
          l.fill(liquid, with: .color(checking ? Palette.done : fill))
        }
        ctx.stroke(shape, with: .color((glow == .waiting ? Palette.waiting.opacity(0.55 + 0.45 * breath) : stateColor.opacity(0.85))), lineWidth: max(1, s * 0.07))

      case .nested:
        let ro = s / 2 - lw / 2, ri = ro - lw * 1.45
        for (r, v) in [(ro, w), (ri, p)] {
          ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.2)), lineWidth: lw)
          ctx.stroke(arc(c, r, 0, max(v, 0.02)), with: .color(Palette.level(v * 100)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        if working { ctx.stroke(arc(c, ro, time * 0.83, time * 0.83 + 0.15), with: .color(Palette.accent), style: StrokeStyle(lineWidth: lw, lineCap: .round)) }
        let d = s * 0.2 * (glow == .waiting ? 0.8 + 0.3 * breath : 1)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(checking ? Palette.done : stateColor))

      case .bars:
        let bw = s * 0.3, gap = s * 0.14, h = s * 0.92
        for (i, v) in [p, w].enumerated() {
          let x = c.x - gap / 2 - bw + CGFloat(i) * (bw + gap)
          let track = CGRect(x: x, y: c.y - h / 2, width: bw, height: h)
          ctx.fill(Path(roundedRect: track, cornerRadius: bw * 0.35), with: .color(.white.opacity(0.2)))
          let fh = max(bw * 0.6, h * v)
          ctx.fill(Path(roundedRect: CGRect(x: x, y: track.maxY - fh, width: bw, height: fh), cornerRadius: bw * 0.35),
                   with: .color(checking ? Palette.done : Palette.level(v * 100)))
          if working {
            let y = track.maxY - h * CGFloat((time * 0.8 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1))
            ctx.fill(Path(CGRect(x: x, y: y, width: bw, height: max(1, s * 0.07))), with: .color(.white.opacity(0.85)))
          }
        }
      }

      // Needs input: a small orange dot, top right.
      if glow == .waiting {
        let d = s * 0.32 * (moving ? 0.85 + 0.15 * breath : 1)
        ctx.fill(Path(ellipseIn: CGRect(x: size.width - d, y: 0, width: d, height: d)), with: .color(Palette.waiting))
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Claude: \(glow.label), 5-hour usage \(Int(pct)) percent, weekly \(Int(week)) percent")
  }

  /// Clockwise arc from 12 o'clock, in fractions of a turn.
  private func arc(_ c: CGPoint, _ r: CGFloat, _ from: Double, _ to: Double) -> Path {
    var p = Path()
    p.addArc(center: c, radius: r, startAngle: .degrees(-90 + 360 * from), endAngle: .degrees(-90 + 360 * to), clockwise: false)
    return p
  }

  /// Four-point Claude-style sparkle.
  private func sparkle(at c: CGPoint, radius r: CGFloat, waist: CGFloat = 0.28) -> Path {
    var p = Path()
    let w = r * waist
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    return p
  }

  private func check(in c: CGPoint, size s: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: c.x - s * 0.5, y: c.y))
    p.addLine(to: CGPoint(x: c.x - s * 0.12, y: c.y + s * 0.38))
    p.addLine(to: CGPoint(x: c.x + s * 0.55, y: c.y - s * 0.4))
    return p
  }
}

/// Live mark that animates itself; static under Reduce Motion.
struct LiveMark: View {
  let store: Store
  @AppStorage("iconStyle") private var styleRaw = IconStyle.ring.rawValue
  var body: some View {
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let idle = !store.glow.animates && Date().timeIntervalSince(store.rippleAt) > 1.5
    TimelineView(.animation(paused: still || idle)) { tl in
      GaugeMark(style: IconStyle(rawValue: styleRaw) ?? .ring, glow: store.glow, pct: store.five?.percentUsed ?? 0,
                week: store.week?.percentUsed ?? 0, time: tl.date.timeIntervalSinceReferenceDate, rippleAge: tl.date.timeIntervalSince(store.rippleAt), still: still)
    }
  }
}

/// Menu bar image (non-template so it keeps its colors), redrawn from the store's frame ticks.
@MainActor func menuBarImage(_ store: Store, style: IconStyle) -> NSImage {
  _ = store.frame
  let now = Date()
  let r = ImageRenderer(content: GaugeMark(
    style: style, glow: store.glow, pct: store.five?.percentUsed ?? 0, week: store.week?.percentUsed ?? 0, time: now.timeIntervalSinceReferenceDate,
    rippleAge: now.timeIntervalSince(store.rippleAt), still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  ).frame(width: 17, height: 17).padding(.horizontal, 1))
  r.scale = NSScreen.main?.backingScaleFactor ?? 2
  let img = r.nsImage ?? NSImage()
  img.isTemplate = false
  img.accessibilityDescription = "Claude Gauge"
  return img
}

/// App icon art; `Gauge --icon <png>` writes it at 1024 px during the build.
struct AppIconArt: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 228, style: .continuous)
        .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
      Circle().fill(Palette.accent.opacity(0.18)).blur(radius: 140).frame(width: 640)
      RoundedRectangle(cornerRadius: 228, style: .continuous)
        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 6)
      GaugeMark(style: .ring, glow: .idle, pct: 62, still: true).frame(width: 600, height: 600)
    }
    .frame(width: 1024, height: 1024)
  }
}
