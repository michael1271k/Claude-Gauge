// Data model: what the usage-gauge mod writes to ~/.claude/gauge, and the rules that turn it into a glow.
import AppKit
import Foundation
import SwiftUI

let gaugeDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/gauge")
let projectsDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
let claudeBundleID = "com.anthropic.claudefordesktop"

struct Limit: Codable, Hashable {
  let kind: String
  let percentUsed: Double
  let resetsAt: String?

  var resetDate: Date? {
    guard let resetsAt else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
  }

  /// How much of the window has passed (0...1): 5 hours or 7 days, counted back from the reset.
  var elapsedFraction: Double? {
    guard let r = resetDate else { return nil }
    let window: Double = kind == "five_hour" ? 5 * 3600 : 7 * 86_400
    return min(1, max(0, 1 - r.timeIntervalSinceNow / window))
  }
}

enum ChatState: String, Codable { case idle, working, waiting, done }

struct Chat: Codable, Identifiable, Hashable {
  let id: String
  let cwd: String
  var project: String = ""
  var label: String = ""
  let usd: Double
  let at: Double
  var limits: [Limit] = []
  var state: ChatState = .idle
  var stateAt: Double = 0
  var question: String = ""
  /// Set by the store from the transcript's latest custom title (the name the Claude sidebar shows).
  var title: String = ""

  enum CodingKeys: String, CodingKey { case id, cwd, project, label, usd, at, limits, state, stateAt, question }

  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
    project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
    label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? 0
    at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
    limits = try c.decodeIfPresent([Limit].self, forKey: .limits) ?? []
    state = (try? c.decodeIfPresent(ChatState.self, forKey: .state)) ?? .idle
    stateAt = try c.decodeIfPresent(Double.self, forKey: .stateAt) ?? at
    question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
  }

  init(id: String, cwd: String, project: String, label: String, usd: Double, at: Double, limits: [Limit] = [], state: ChatState, stateAt: Double, question: String = "", title: String = "") {
    self.id = id; self.cwd = cwd; self.project = project; self.label = label; self.usd = usd; self.at = at
    self.limits = limits; self.state = state; self.stateAt = stateAt; self.question = question; self.title = title
  }

  var displayTitle: String { !title.isEmpty ? title : !label.isEmpty ? label : project.isEmpty ? "Chat" : project }
  var displayProject: String { project.isEmpty ? (cwd as NSString).lastPathComponent : project }

  /// A chat whose process died mid-turn stops counting as working after 30 minutes.
  func liveState(now: Double) -> ChatState {
    state == .working && now - stateAt > 30 * 60_000 ? .idle : state
  }

  /// ~/.claude/projects/<cwd with every non-alphanumeric character as "-">/<id>.jsonl
  var transcriptURL: URL {
    let folder = String(cwd.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
    return projectsDir.appending(path: folder).appending(path: "\(id).jsonl")
  }
}

struct Day: Identifiable, Hashable {
  let date: Date
  let usd: Double
  var id: Date { date }
}

enum Glow: String, CaseIterable {
  case idle, working, waiting, done, hot

  var color: Color {
    switch self {
    case .idle: Color(white: 0.92)
    case .working: Palette.accent
    case .waiting: Palette.waiting
    case .done: Palette.done
    case .hot: Palette.hot
    }
  }

  var label: String {
    switch self {
    case .idle: "Idle"
    case .working: "Running"
    case .waiting: "Needs input"
    case .done: "Done"
    case .hot: "Near limit"
    }
  }

  var animates: Bool { self == .working || self == .waiting }

  /// SF Symbol for the state badge.
  var symbol: String {
    switch self {
    case .idle: "moon.zzz.fill"
    case .working: "bolt.fill"
    case .waiting: "exclamationmark.bubble.fill"
    case .done: "checkmark.circle.fill"
    case .hot: "flame.fill"
    }
  }

  /// Waiting beats working beats unread-done beats a hot limit.
  static func of(_ chats: [Chat], seenAt: Double, maxPct: Double, now: Double) -> Glow {
    let recent = chats.filter { now - $0.at < 6 * 3_600_000 }
    let states = recent.map { ($0.liveState(now: now), $0.stateAt) }
    if states.contains(where: { $0.0 == .waiting }) { return .waiting }
    if states.contains(where: { $0.0 == .working }) { return .working }
    if states.contains(where: { $0.0 == .done && $0.1 > seenAt }) { return .done }
    return maxPct >= 80 ? .hot : .idle
  }
}

/// An appearance: main and secondary colors plus the chart color. State colors (needs input, done, near limit) stay fixed
/// so they always mean the same thing.
struct Theme: Identifiable {
  let id: String
  let accent: Color
  let secondary: Color
  let chart: Color

  static let all: [Theme] = [
    Theme(id: "Ocean", accent: Color(hex: 0x63D1FF), secondary: Color(hex: 0xFFD63F), chart: Color(hex: 0x63D1FF)),
    Theme(id: "Clay", accent: Color(hex: 0xE08A66), secondary: Color(hex: 0xF3D9C4), chart: Color(hex: 0xD97757)),
    Theme(id: "Aurora", accent: Color(hex: 0xA78BFA), secondary: Color(hex: 0x5EEAD4), chart: Color(hex: 0x8B7CF6)),
    Theme(id: "Sunset", accent: Color(hex: 0xFF8A65), secondary: Color(hex: 0xF9A8D4), chart: Color(hex: 0xFF7A59)),
    Theme(id: "Graphite", accent: Color(hex: 0xE5E7EB), secondary: Color(hex: 0xA3A9B3), chart: Color(hex: 0xC4C8CF)),
  ]

  /// The theme picked in Settings; "Custom" uses the two colors picked there.
  static var current: Theme {
    let d = UserDefaults.standard
    let id = d.string(forKey: "theme") ?? "Ocean"
    if id == "Custom" {
      let a = Color(hex: d.object(forKey: "customAccent") as? Int ?? 0x63D1FF)
      return Theme(id: id, accent: a, secondary: Color(hex: d.object(forKey: "customSecondary") as? Int ?? 0xFFD63F), chart: a)
    }
    return all.first { $0.id == id } ?? all[0]
  }
}

extension Color {
  init(hex: Int) {
    self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }

  var hex: Int {
    guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
    return Int(c.redComponent * 255) << 16 | Int(c.greenComponent * 255) << 8 | Int(c.blueComponent * 255)
  }
}

enum Palette {
  static var accent: Color { Theme.current.accent }
  static var secondary: Color { Theme.current.secondary }
  static var chart: Color { Theme.current.chart }
  static let waiting = Color(red: 1.0, green: 0.62, blue: 0.2)
  static let done = Color(red: 0.25, green: 0.86, blue: 0.5)
  static let hot = Color(red: 1.0, green: 0.33, blue: 0.33)
  static let warn = Color(red: 1, green: 0.84, blue: 0.25)
  static func level(_ pct: Double) -> Color { pct >= 80 ? hot : pct >= 50 ? warn : done }
  static func state(_ s: ChatState) -> Color {
    switch s {
    case .waiting: waiting
    case .working: accent
    case .done: done
    case .idle: Color(white: 0.5)
    }
  }
}

enum Format {
  /// "$0.42", "$14.8", "$350", "$1,009", "$12,480".
  static func money(_ v: Double) -> String {
    v >= 1000 ? "$" + v.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
      : v >= 100 ? String(format: "$%.0f", v) : v >= 10 ? String(format: "$%.1f", v) : String(format: "$%.2f", v)
  }
  static func axisMoney(_ v: Double) -> String { v == 0 ? "$0" : v < 1 ? String(format: "$%.1f", v) : String(format: "$%.0f", v) }
  static func until(_ date: Date?) -> String {
    guard let date else { return "" }
    let m = max(0, Int(date.timeIntervalSinceNow / 60))
    return m >= 1440 ? "\(m / 1440)d \(m % 1440 / 60)h" : m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
  }
  static func ago(_ ms: Double) -> String {
    let s = Int(Date().timeIntervalSince1970 - ms / 1000)
    return s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
  }
  static func minutes(_ m: Double) -> String { m >= 60 ? "\(Int(m) / 60)h \(Int(m) % 60)m" : "\(Int(m))m" }
}

enum Greeting {
  static func salutation(hour: Int) -> String {
    switch hour {
    case 5..<12: "Good morning"
    case 12..<17: "Good afternoon"
    case 17..<21: "Good evening"
    default: "Good night"
    }
  }
  /// Set by `--snapshot` so review images show a sample name.
  nonisolated(unsafe) static var override: String?
  static var firstName: String {
    override ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
  }
  static func now() -> String { "\(salutation(hour: Calendar.current.component(.hour, from: .now))), \(firstName)" }
}

/// Minutes until the 5-hour window is used up at the recent rate; nil when not rising.
func minutesLeft(samples: [(t: Double, pct: Double)]) -> Double? {
  guard let first = samples.first, let last = samples.last, last.t - first.t >= 120, last.pct > first.pct else { return nil }
  let perMinute = (last.pct - first.pct) / ((last.t - first.t) / 60)
  return (100 - last.pct) / perMinute
}
