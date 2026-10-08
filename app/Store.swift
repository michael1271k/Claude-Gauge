// Gauge store: reads ~/.claude/gauge, resolves live chat titles and true spend from transcripts, announces state changes.
import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor @Observable final class Store {
  var chats: [Chat] = []
  var days: [Day] = []
  /// Per chat: spend by day, model and effort (from the ledger).
  var spend: [String: ChatSpend] = [:]
  var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedChats") ?? [])
  /// Chat id → when it was hidden; it comes back on new activity.
  var hidden: [String: Double] = UserDefaults.standard.dictionary(forKey: "hiddenChats") as? [String: Double] ?? [:]
  /// Ticks ~15 fps while the logo animates, so the menu bar image redraws.
  var frame = 0
  var rippleAt: Date = .distantPast
  /// Bumped when any chat starts waiting on the user; the widget opens itself on it.
  var needsInputAt: Date = .distantPast
  var updatedAt: Double = 0
  /// What each running chat is doing (Agents tab).
  var activity: [String: Activity] = [:]
  private var readingActivity = false
  private var lastActivity = Date.distantPast

  private let ledger = Ledger()
  private var scanning = false
  private var lastScan = Date.distantPast
  private var lastStates: [String: ChatState]?
  private var titleCache: [String: (mtime: Date, title: String)] = [:]
  private var fiveSamples: [(t: Double, pct: Double)] = []

  /// The newest limits any chat has seen (limits.json, written by the mod): the same numbers the in-chat bar shows.
  var limits: [Limit] = []
  var syncedAt: Date = .distantPast
  /// The user's own order of chats (drag to reorder).
  var order: [String] = UserDefaults.standard.stringArray(forKey: "chatOrder") ?? []
  func limit(_ kind: String) -> Limit? { limits.first { $0.kind == kind } }
  var five: Limit? { limit("five_hour") }
  var week: Limit? { limit("seven_day") }
  var maxPct: Double { limits.map(\.percentUsed).max() ?? 0 }
  var current: Chat? { chats.first }
  var nowMs: Double { Date().timeIntervalSince1970 * 1000 }
  var seenAt: Double { UserDefaults.standard.double(forKey: "seenAt") }
  var glow: Glow { Glow.of(chats, seenAt: seenAt, maxPct: maxPct, now: nowMs) }
  var paceMinutesLeft: Double? { minutesLeft(samples: fiveSamples) }

  /// Calendar whose week starts on the day chosen in Settings (Sunday by default).
  static var calendar: Calendar {
    var c = Calendar.current
    c.firstWeekday = UserDefaults.standard.string(forKey: "weekStart") == "Monday" ? 2 : 1
    return c
  }

  func spent(since start: Date) -> Double { days.filter { $0.date >= start }.reduce(0) { $0 + $1.usd } }
  var today: Double { spent(since: Calendar.current.startOfDay(for: .now)) }
  /// Since the start of this week (Sunday or Monday, per Settings).
  var thisWeek: Double { spent(since: Self.calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now) }
  /// Since the 1st of this month.
  var thisMonth: Double { spent(since: Self.calendar.dateInterval(of: .month, for: .now)?.start ?? .now) }

  func todaySpend(_ c: Chat) -> Double { spend[c.id]?.byDay[dayKey(.now)] ?? 0 }
  func totalSpend(_ c: Chat) -> Double { max(c.usd, spend[c.id]?.total ?? 0) }
  func modelText(_ c: Chat) -> String { spend[c.id].map { modelLabel($0.model, effort: $0.effort) } ?? "" }

  /// The last `n` days including empty ones, so the chart keeps a steady rhythm.
  func series(_ n: Int) -> [Day] {
    let cal = Calendar.current
    let byDay = Dictionary(days.map { (cal.startOfDay(for: $0.date), $0.usd) }, uniquingKeysWith: +)
    return (0..<n).reversed().map { back in
      let d = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: .now))!
      return Day(date: d, usd: byDay[d] ?? 0)
    }
  }

  func markSeen() { UserDefaults.standard.set(nowMs, forKey: "seenAt") }

  func togglePin(_ c: Chat) {
    if pinned.remove(c.id) == nil { pinned.insert(c.id) }
    UserDefaults.standard.set(Array(pinned), forKey: "pinnedChats")
  }

  func hide(_ c: Chat) {
    hidden[c.id] = nowMs
    pinned.remove(c.id)
    UserDefaults.standard.set(hidden, forKey: "hiddenChats")
    UserDefaults.standard.set(Array(pinned), forKey: "pinnedChats")
  }

  func isHidden(_ c: Chat) -> Bool { hidden[c.id].map { c.at <= $0 } ?? false }

  func load() {
    let dec = JSONDecoder()
    let files = (try? FileManager.default.contentsOfDirectory(at: gaugeDir.appending(path: "sessions"), includingPropertiesForKeys: nil)) ?? []
    let weekAgo = nowMs - 7 * 86_400_000
    var loaded = files.compactMap { try? dec.decode(Chat.self, from: Data(contentsOf: $0)) }.filter { $0.at > weekAgo || pinned.contains($0.id) }
    for i in loaded.indices { loaded[i].title = title(for: loaded[i]) }
    let now = nowMs
    chats = loaded.sorted {
      let a = $0.liveState(now: now) == .waiting, b = $1.liveState(now: now) == .waiting
      return a != b ? a : $0.at > $1.at
    }
    updatedAt = chats.map(\.at).max() ?? 0
    readLimits()

    if let pct = five?.percentUsed {
      let t = Date().timeIntervalSince1970
      if fiveSamples.last?.pct != pct || fiveSamples.isEmpty { fiveSamples.append((t, pct)) }
      if let last = fiveSamples.last, last.pct < (fiveSamples.first?.pct ?? 0) { fiveSamples = [last] } // window reset
      fiveSamples.removeAll { t - $0.t > 20 * 60 }
    }
    announceChanges()
    if Date().timeIntervalSince(lastScan) > 3 { scanSpend() }
    if Date().timeIntervalSince(lastActivity) > 2 { refreshActivity() }
  }

  /// Re-reads the running chats' transcript tails off the main thread.
  private func refreshActivity() {
    guard !readingActivity else { return }
    let targets = agentChats.map { ($0.id, $0.transcriptURL) }
    lastActivity = .now
    guard !targets.isEmpty else { activity = [:]; return }
    readingActivity = true
    Task.detached {
      let r = Dictionary(targets.map { ($0.0, readActivity($0.1)) }, uniquingKeysWith: { a, _ in a })
      await MainActor.run {
        self.activity = r
        self.readingActivity = false
      }
    }
  }

  private func readLimits() {
    struct Shared: Decodable { let limits: [Limit]; let at: Double }
    let shared = try? JSONDecoder().decode(Shared.self, from: Data(contentsOf: gaugeDir.appending(path: "limits.json")))
    let newestChat = chats.filter { !$0.limits.isEmpty }.max { $0.at < $1.at }
    if let shared, shared.at >= (newestChat?.at ?? 0) { limits = shared.limits } else if let c = newestChat { limits = c.limits }
  }

  /// Asks every open chat's mod to re-read its usage now (they answer within 10 s), and re-counts spend.
  func sync() {
    let data = try? JSONSerialization.data(withJSONObject: ["at": nowMs])
    try? data?.write(to: gaugeDir.appending(path: "sync.json"), options: .atomic)
    syncedAt = .now
    lastScan = .distantPast
    load()
    for delay in [3.0, 6.0, 11.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.load() }
    }
  }

  /// Puts `id` where `before` is (or last), in the user's own order.
  func move(_ id: String, before: String?) {
    var ids = rankedChats.map(\.id)
    ids.removeAll { $0 == id }
    ids.insert(id, at: before.flatMap { ids.firstIndex(of: $0) } ?? ids.endIndex)
    order = ids
    UserDefaults.standard.set(ids, forKey: "chatOrder")
  }

  /// Re-reads what changed in the transcripts (off the main thread) and refreshes days, per-chat spend and totals.json.
  private func scanSpend() {
    guard !scanning else { return }
    scanning = true
    lastScan = .now
    let live = Dictionary(chats.map { ($0.id, $0.usd) }, uniquingKeysWith: max)
    Task {
      let r = await ledger.scan(live: live)
      let fmt = DateFormatter()
      fmt.dateFormat = "yyyy-MM-dd"
      days = r.days.compactMap { k, v in fmt.date(from: k).map { Day(date: $0, usd: v) } }.sorted { $0.date < $1.date }
      spend = r.chats
      scanning = false
      writeTotals()
      writeModels()
    }
  }

  /// Each chat's model and effort as its transcript records them, for the in-chat bar before its first request.
  private var lastModels: [String: [String: String]] = [:]
  private func writeModels() {
    let m = spend.filter { !$0.value.model.isEmpty }.mapValues { ["model": $0.model, "effort": $0.effort] }
    guard m != lastModels, let data = try? JSONSerialization.data(withJSONObject: m) else { return }
    lastModels = m
    try? data.write(to: gaugeDir.appending(path: "models.json"), options: .atomic)
  }

  /// Today / week / month for the mod's in-chat bar.
  private var lastTotals: [String: Double] = [:]
  private func writeTotals() {
    let t = ["today": today, "week": thisWeek, "month": thisMonth]
    guard t != lastTotals else { return }
    lastTotals = t
    var out: [String: Any] = t
    out["at"] = nowMs
    if let data = try? JSONSerialization.data(withJSONObject: out) { try? data.write(to: gaugeDir.appending(path: "totals.json"), options: .atomic) }
  }

  /// Latest `custom-title` line in the chat's transcript (the name in Claude's sidebar), cached by mtime.
  private func title(for chat: Chat) -> String {
    let url = chat.transcriptURL
    guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
    if let hit = titleCache[chat.id], hit.mtime == mtime { return hit.title }
    var found = titleCache[chat.id]?.title ?? ""
    if let h = try? FileHandle(forReadingFrom: url) {
      defer { try? h.close() }
      let size = (try? h.seekToEnd()) ?? 0
      try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
      if let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) {
        for line in text.split(separator: "\n").reversed() where line.contains("\"custom-title\"") {
          if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let t = obj["customTitle"] as? String {
            found = t
            break
          }
        }
      }
    }
    titleCache[chat.id] = (mtime, found)
    return found
  }

  /// Sound + notification when a chat starts waiting on the user or finishes. Silent on the first load.
  private func announceChanges() {
    let now = nowMs
    let states = Dictionary(chats.map { ($0.id, $0.liveState(now: now)) }, uniquingKeysWith: { a, _ in a })
    defer { lastStates = states }
    guard let before = lastStates else { return }
    let d = UserDefaults.standard
    for c in chats where states[c.id] != before[c.id] {
      switch states[c.id] {
      case .working:
        emit(sound: d.string(forKey: "soundRunning") ?? "None", chat: c, title: "", body: "", notify: false)
      case .waiting:
        needsInputAt = .now
        emit(sound: d.string(forKey: "soundWaiting") ?? "Glass", chat: c, title: "\(c.displayTitle) needs you", body: c.question.isEmpty ? "Claude is waiting for your answer" : c.question)
      case .done:
        rippleAt = .now
        emit(sound: d.string(forKey: "soundDone") ?? "Hero", chat: c, title: "\(c.displayTitle) is done", body: "Click to open the chat")
      default: break
      }
    }
  }

  private func emit(sound: String, chat: Chat, title: String, body: String, notify: Bool = true) {
    let d = UserDefaults.standard
    if d.object(forKey: "soundsOn") as? Bool ?? true, sound != "None" { NSSound(named: sound)?.play() }
    guard notify, d.object(forKey: "notificationsOn") as? Bool ?? true else { return }
    let n = UNMutableNotificationContent()
    n.title = title
    n.body = body
    n.userInfo = ["session": chat.id]
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
  }
}

/// Opens one chat in the Claude app (its resume deep link), else just brings Claude forward.
func openChat(_ chat: Chat) { openChat(id: chat.id) }

func openChat(id: String) {
  if let url = URL(string: "claude://resume?session=\(id)"), NSWorkspace.shared.open(url) { return }
  openClaude()
}

func openClaude() {
  guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return }
  NSWorkspace.shared.openApplication(at: url, configuration: .init())
}
