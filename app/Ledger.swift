// True spend per day and per chat, read from Claude's own transcripts. Each chat's latest cost-state total is
// spread over its replies by token weight and timestamp, so reopening an old chat never counts its cost again.
import Foundation

struct ChatSpend: Sendable {
  var byDay: [String: Double] = [:]
  var total: Double = 0
  /// Model and effort of the chat's latest reply, e.g. "claude-opus-5-5", "xhigh".
  var model = ""
  var effort = ""
  /// The chat's working directory (its project).
  var cwd = ""
}

actor Ledger {
  private struct Reply { var model: String; var day: String; var weight: Double }
  private struct FileState {
    var mtime = Date.distantPast
    var offset: UInt64 = 0
    var replies: [String: Reply] = [:]
    /// Model → USD from the latest cost-state line (main transcript only).
    var cost: [String: Double] = [:]
    var model = ""
    var effort = ""
    var cwd = ""
  }

  private var files: [String: FileState] = [:]
  /// Recently written transcripts: session → (working directory, last write), including sub-agents' files.
  private(set) var touched: [String: (cwd: String, at: Date)] = [:]
  /// Session → day → USD. Persisted so chats whose transcripts are deleted keep their history.
  private var saved: [String: [String: Double]]
  private let savedURL = gaugeDir.appending(path: "ledger.json")
  private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  init() {
    saved = (try? JSONDecoder().decode([String: [String: Double]].self, from: Data(contentsOf: gaugeDir.appending(path: "ledger.json")))) ?? [:]
  }

  /// `live`: running chats' totals from the mod, which can be newer than their last cost-state line.
  func scan(live: [String: Double]) -> (days: [String: Double], chats: [String: ChatSpend], touched: [String: (cwd: String, at: Date)]) {
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-40 * 86_400)
    var chats: [String: ChatSpend] = [:]
    for dir in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
      for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
        guard let m = mtime(f), m > cutoff else { continue }
        let id = f.deletingPathExtension().lastPathComponent
        let subagents = ((try? fm.contentsOfDirectory(at: dir.appending(path: "\(id)/subagents"), includingPropertiesForKeys: nil)) ?? [])
          .filter { $0.pathExtension == "jsonl" }
        let paths = [f.path] + subagents.map(\.path)
        paths.forEach(read)
        guard let main = files[f.path] else { continue }
        let last = ([m] + subagents.compactMap(mtime)).max() ?? m
        if Date().timeIntervalSince(last) < 2 * 3600 { touched[id] = (main.cwd, last) } else { touched[id] = nil }
        var weights: [String: [String: Double]] = [:]
        for p in paths {
          for r in files[p].map({ Array($0.replies.values) }) ?? [] { weights[r.model, default: [:]][r.day, default: 0] += r.weight }
        }
        var cost = main.cost
        let known = cost.values.reduce(0, +)
        if let l = live[id], l > known + 0.001 {
          cost = known > 0 ? cost.mapValues { $0 * l / known } : ["": l]
        }
        let byDay = Ledger.allocate(cost: cost, weights: weights)
        saved[id] = byDay
        chats[id] = ChatSpend(byDay: byDay, total: byDay.values.reduce(0, +), model: main.model, effort: main.effort, cwd: main.cwd)
      }
    }
    persist()
    var days: [String: Double] = [:]
    for byDay in saved.values { for (d, v) in byDay { days[d, default: 0] += v } }
    return (days, chats, touched)
  }

  /// Spreads each model's cost over the days its replies happened, by token weight.
  /// A model with no replies on record (rare) is spread over all of the chat's replies.
  static func allocate(cost: [String: Double], weights: [String: [String: Double]]) -> [String: Double] {
    var all: [String: Double] = [:]
    for days in weights.values { for (d, w) in days { all[d, default: 0] += w } }
    var out: [String: Double] = [:]
    for (model, usd) in cost where usd > 0 {
      let own = weights[model] ?? [:]
      let src = own.values.reduce(0, +) > 0 ? own : all
      let total = src.values.reduce(0, +)
      guard total > 0 else { continue }
      for (d, w) in src { out[d, default: 0] += usd * w / total }
    }
    return out
  }

  /// Relative price of a reply's tokens (input = 1). Only the ratios matter: the cost-state supplies the dollars.
  static func weight(_ u: [String: Any]) -> Double {
    func n(_ k: String, _ o: [String: Any]? = nil) -> Double { ((o ?? u)[k] as? NSNumber)?.doubleValue ?? 0 }
    let cc = u["cache_creation"] as? [String: Any]
    let write = cc.map { 1.25 * n("ephemeral_5m_input_tokens", $0) + 2 * n("ephemeral_1h_input_tokens", $0) }
      ?? 1.25 * n("cache_creation_input_tokens")
    return n("input_tokens") + 5 * n("output_tokens") + 0.1 * n("cache_read_input_tokens") + write
  }

  private static let costMark = Data(#"{"type":"cost-state""#.utf8)
  private static let replyMark = Data(#""type":"assistant""#.utf8)
  private static let usageMark = Data(#""usage""#.utf8)

  /// Reads only what was appended since last time.
  private func read(_ path: String) {
    let url = URL(fileURLWithPath: path)
    guard let m = mtime(url) else { return }
    var st = files[path] ?? FileState()
    guard m != st.mtime, let h = FileHandle(forReadingAtPath: path) else { return }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    if size < st.offset { st = FileState() } // rewritten
    st.mtime = m
    try? h.seek(toOffset: st.offset)
    guard let data = try? h.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { files[path] = st; return }
    let chunk = data[data.startIndex...lastNewline]
    st.offset += UInt64(chunk.count)
    for line in chunk.split(separator: 0x0A) { parse(Data(line), into: &st) }
    files[path] = st
  }

  private func parse(_ line: Data, into st: inout FileState) {
    if line.starts(with: Self.costMark) {
      guard let o = json(line), let usage = o["modelUsage"] as? [String: [String: Any]] else { return }
      st.cost = usage.compactMapValues { ($0["costUSD"] as? NSNumber)?.doubleValue }
      return
    }
    guard line.range(of: Self.replyMark) != nil, line.range(of: Self.usageMark) != nil, let o = json(line),
          let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
          let ts = o["timestamp"] as? String, let date = iso.date(from: ts) else { return }
    let model = msg["model"] as? String ?? ""
    // Streamed replies repeat their usage on every content block; the last copy wins.
    let key = msg["id"] as? String ?? o["requestId"] as? String ?? UUID().uuidString
    st.replies[key] = Reply(model: model, day: dayKey(date), weight: Self.weight(u))
    if !model.hasPrefix("<") { st.model = model }
    if let e = o["effort"] as? String { st.effort = e }
    if let c = o["cwd"] as? String { st.cwd = c }
  }

  private func json(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
  private func mtime(_ u: URL) -> Date? { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

  private var lastSaved: [String: [String: Double]] = [:]
  private func persist() {
    guard saved != lastSaved, let data = try? JSONEncoder().encode(saved) else { return }
    try? data.write(to: savedURL, options: .atomic)
    lastSaved = saved
  }
}

/// "2026-10-08" in the local time zone.
func dayKey(_ d: Date) -> String {
  let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
  return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// "claude-opus-5-5" + "xhigh" → "Opus 5.5 · Extra high".
func modelLabel(_ model: String, effort: String) -> String {
  let parts = model.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init).filter { $0.count < 8 }
  guard let family = parts.first else { return "" }
  let name = family.prefix(1).uppercased() + family.dropFirst() + (parts.count > 1 ? " " + parts.dropFirst().joined(separator: ".") : "")
  let e = ["low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra high", "max": "Max"][effort] ?? effort.capitalized
  return e.isEmpty ? name : "\(name) · \(e)"
}
