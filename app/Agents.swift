// The Agents tab: every running chat with its current mission, live activity, sub-agents and a time estimate,
// read from the tail of its transcript.
import SwiftUI

struct SubAgent: Identifiable, Sendable {
  let id: String
  let kind: String
  let task: String
  let started: Date
  var finished: Date?
}

struct Activity: Sendable {
  /// The prompt Claude is working on now, and when it was sent.
  var prompt = ""
  var promptAt: Date?
  /// "Editing Widget.swift", "Running build.sh", …
  var doing = ""
  /// The last few steps, newest last (live peek).
  var recent: [String] = []
  /// The answer choices of the question Claude is waiting on (quick reply).
  var choices: [String] = []
  var tools = 0
  var agents: [SubAgent] = []

  var running: Int { agents.filter { $0.finished == nil }.count }
  var finished: Int { agents.count - running }
  /// From the average time of finished sub-agents; nil until one finishes.
  func minutesLeft(now: Date = .now) -> Double? {
    let done = agents.compactMap { a in a.finished.map { $0.timeIntervalSince(a.started) } }
    guard !done.isEmpty, let oldest = agents.filter({ $0.finished == nil }).map(\.started).min() else { return nil }
    let avg = done.reduce(0, +) / Double(done.count)
    return max(1, (avg - now.timeIntervalSince(oldest)) / 60)
  }
}

/// Reads the last 2 MB of a transcript: the latest real prompt, then every tool call and sub-agent since.
func readActivity(_ url: URL) -> Activity {
  var a = Activity()
  guard let h = try? FileHandle(forReadingFrom: url) else { return a }
  defer { try? h.close() }
  let size = (try? h.seekToEnd()) ?? 0
  try? h.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
  guard let data = try? h.readToEnd() else { return a }
  let iso = ISO8601DateFormatter()
  iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  var results: Set<String> = []
  var resultAt: [String: Date] = [:]

  for line in data.split(separator: 0x0A) {
    let isUser = line.range(of: Data(#""type":"user""#.utf8)) != nil
    guard isUser || line.range(of: Data(#""type":"tool_use""#.utf8)) != nil,
          let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
          let msg = o["message"] as? [String: Any], (o["isSidechain"] as? Bool) != true else { continue }
    let at = (o["timestamp"] as? String).flatMap(iso.date(from:)) ?? .now
    let blocks = msg["content"] as? [[String: Any]] ?? []
    if o["type"] as? String == "user" {
      for b in blocks where b["type"] as? String == "tool_result" {
        if let id = b["tool_use_id"] as? String { results.insert(id); resultAt[id] = at }
      }
      if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { a.choices = [] } // answered
      // The person's words: every text part with the app's injected <tags>…</tags> removed; the latest prompt wins.
      let parts = (msg["content"] as? String).map { [$0] } ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
      let t = parts.map(stripTags).filter { !$0.isEmpty }.joined(separator: " ")
      if !t.isEmpty, (o["isMeta"] as? Bool) != true {
        // Sub-agents still running from an earlier turn stay on the card.
        a = Activity(prompt: t.replacingOccurrences(of: "\n", with: " "), promptAt: at, agents: a.agents)
        results = []
      }
    } else {
      for b in blocks where b["type"] as? String == "tool_use" {
        let name = b["name"] as? String ?? ""
        let input = b["input"] as? [String: Any] ?? [:]
        a.tools += 1
        a.doing = describe(name, input)
        a.recent = Array((a.recent + [a.doing]).suffix(3))
        if name == "AskUserQuestion", let q = (input["questions"] as? [[String: Any]])?.first {
          a.choices = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        }
        if name == "Agent" || name == "Task", let id = b["id"] as? String {
          a.agents.append(SubAgent(id: id, kind: input["subagent_type"] as? String ?? "agent",
                                   task: input["description"] as? String ?? "", started: at))
        }
      }
    }
  }

  let promptAt = a.promptAt ?? .distantPast
  // A sub-agent is done once its own transcript goes quiet (background ones), or its result came back.
  let dir = url.deletingPathExtension().appending(path: "subagents")
  var files: [String: URL] = [:]
  for meta in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where meta.lastPathComponent.hasSuffix(".meta.json") {
    if let o = (try? JSONSerialization.jsonObject(with: Data(contentsOf: meta))) as? [String: Any], let id = o["toolUseId"] as? String {
      files[id] = dir.appending(path: meta.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
    }
  }
  for i in a.agents.indices {
    let id = a.agents[i].id
    if let f = files[id], let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
      if Date().timeIntervalSince(m) > 45 { a.agents[i].finished = m }
    } else if results.contains(id) {
      a.agents[i].finished = resultAt[id]
    }
  }
  a.agents.removeAll { $0.finished != nil && $0.started < promptAt }
  return a
}

/// Removes `<system-reminder>…</system-reminder>`-style blocks and stray tags the apps add around a prompt.
func stripTags(_ text: String) -> String {
  var t = text.replacingOccurrences(of: #"<([A-Za-z_-]+)[^>]*>[\s\S]*?</\1>"#, with: "", options: .regularExpression)
  t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
  return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func describe(_ name: String, _ input: [String: Any]) -> String {
  let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
  switch name {
  case "Bash": return "Running " + ((input["description"] as? String) ?? (input["command"] as? String) ?? "a command")
  case "Edit", "MultiEdit": return "Editing \(file)"
  case "Write": return "Writing \(file)"
  case "Read": return "Reading \(file)"
  case "Grep", "Glob": return "Searching the code"
  case "WebSearch": return "Searching the web: " + ((input["query"] as? String) ?? "")
  case "WebFetch": return "Reading a web page"
  case "Agent", "Task": return "Starting a sub-agent: " + ((input["description"] as? String) ?? "")
  case "AskUserQuestion": return "Asking you a question"
  case "ExitPlanMode": return "Waiting for you to approve the plan"
  case "Skill": return "Using skill " + ((input["skill"] as? String) ?? "")
  default: return name.hasPrefix("mcp__") ? "Using " + (name.split(separator: "_").last.map(String.init) ?? name) : name
  }
}

// MARK: Views

enum GaugeTab: String, CaseIterable { case overview = "Overview", agents = "Agents", projects = "Projects" }

/// Overview | Agents (n) switch under the header, with the Prompt Pad button beside it.
struct TabSwitch: View {
  @Binding var tab: String
  let agents: Int
  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 2) {
        ForEach(GaugeTab.allCases, id: \.self) { t in
          let on = tab == t.rawValue
          Button { withAnimation(widgetSpring) { tab = t.rawValue } } label: {
            HStack(spacing: 4) {
              Text(t.rawValue)
              if t == .agents, agents > 0 {
                Text("\(agents)").font(.system(size: 9, weight: .bold).monospacedDigit())
                  .padding(.horizontal, 4).padding(.vertical, 0.5)
                  .background(Capsule().fill(Palette.accent.opacity(on ? 0.35 : 0.22)))
              }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(on ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.accent.opacity(on ? 0.2 : 0)))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(2)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
      IconButton(symbol: "note.text", hint: "Prompt Pad: saved prompts") { Windows.showPad() }
        .font(.system(size: 12))
    }
  }
}

struct AgentsView: View {
  let store: Store
  var body: some View {
    let chats = store.agentChats
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel(text: "Running")
      if chats.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.tertiary)
          Text("Nothing running right now").font(.system(size: 12, weight: .medium))
          Text("Chats show up here while Claude works, with what they're doing and how far along they are.")
            .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
      } else {
        ForEach(chats.prefix(4)) { AgentCard(chat: $0, store: store) }
        if chats.count > 4 { Text("\(chats.count - 4) more running").font(.system(size: 10)).foregroundStyle(.tertiary) }
      }

    }
  }
}

struct AgentCard: View {
  let chat: Chat
  let store: Store
  @State private var hover = false

  var body: some View {
    let s = chat.liveState(now: store.nowMs)
    let tint = Palette.state(s)
    let act = store.activity[chat.id] ?? Activity()
    let since = act.promptAt ?? Date(timeIntervalSince1970: chat.stateAt / 1000)
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        stateIcon(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
        Text(chat.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        ModelChip(store: store, chat: chat)
        Spacer(minLength: 4)
        Text(s == .done ? "done \(Format.ago(chat.stateAt))" : Format.minutes(max(0, Date().timeIntervalSince(since) / 60)))
          .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
      }
      // What it is doing right now, big; what it was asked, small.
      Text(currentTask(s, act)).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        .foregroundStyle(s == .waiting ? AnyShapeStyle(Palette.waiting) : AnyShapeStyle(LinearGradient(colors: [Palette.accent, Palette.secondary], startPoint: .leading, endPoint: .trailing)))
      let mission = act.prompt.isEmpty ? chat.label : act.prompt
      if !mission.isEmpty {
        Text(mission).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
      }
      ProgressLine(state: s, activity: act)
      if s == .working, act.recent.count > 1 {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(act.recent.dropLast().reversed().enumerated()), id: \.offset) { _, step in
            HStack(spacing: 6) {
              Circle().fill(.white.opacity(0.3)).frame(width: 4, height: 4)
              Text(step).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
      }
      if !act.agents.isEmpty, s != .done {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(act.agents.suffix(4)) { a in
            HStack(spacing: 6) {
              Circle().fill(a.finished == nil ? Palette.accent : Palette.done).frame(width: 5, height: 5)
              Text(a.kind).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.secondary)
              Text(a.task).font(.system(size: 10.5)).lineLimit(1)
              Spacer(minLength: 4)
              Text(Format.minutes(max(0, (a.finished ?? .now).timeIntervalSince(a.started) / 60)))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
          }
        }
      }
      HStack {
        Text(progressText(act, s)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
        Spacer()
        MoneyPair(today: store.todaySpend(chat), total: store.totalSpend(chat))
      }
    }
    .padding(11)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(hover ? 0.14 : 0.08)))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1))
    .contentShape(Rectangle())
    .onTapGesture { openChat(chat) }
    .onHover { hover = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Opens this chat in Claude")
  }

  private func currentTask(_ s: ChatState, _ a: Activity) -> String {
    switch s {
    case .waiting: chat.question.isEmpty ? "Waiting for your answer" : chat.question
    case .done: "Finished"
    default: a.doing.isEmpty ? "Working…" : a.doing
    }
  }

  private func progressText(_ a: Activity, _ s: ChatState) -> String {
    guard !a.agents.isEmpty, s != .done else { return a.tools > 0 ? "\(a.tools) steps" : "" }
    let eta = a.minutesLeft().map { " · ≈\(Format.minutes($0)) left" } ?? ""
    return "\(a.finished) of \(a.agents.count) agents\(eta)"
  }
}

/// Real progress when sub-agents give a total; otherwise a moving shimmer that says "busy", not "x%".
struct ProgressLine: View {
  let state: ChatState
  let activity: Activity
  var body: some View {
    let tint = Palette.state(state)
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.08))
        if state == .done {
          Capsule().fill(tint)
        } else if !activity.agents.isEmpty {
          Capsule().fill(tint).frame(width: max(4, g.size.width * CGFloat(activity.finished) / CGFloat(activity.agents.count)))
        } else if state == .working {
          TimelineView(.animation(paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { tl in
            let p = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Capsule().fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
              .frame(width: g.size.width * 0.3)
              .offset(x: g.size.width * (1.3 * p - 0.3))
          }
          .clipShape(Capsule())
        } else {
          Capsule().fill(tint.opacity(0.6)).frame(width: g.size.width * 0.5)
        }
      }
    }
    .frame(height: 3)
  }
}

/// "Opus 5.5 · XH", tinted by model family.
struct ModelChip: View {
  let store: Store
  let chat: Chat
  var body: some View {
    if let sp = store.spend[chat.id], !sp.model.isEmpty {
      let family = sp.model.contains("opus") ? Color(red: 0.72, green: 0.6, blue: 1)
        : sp.model.contains("haiku") ? Palette.done
        : sp.model.contains("fable") ? Color(red: 1, green: 0.55, blue: 0.45) : Palette.accent
      Text(modelChipText(sp.model, effort: sp.effort))
        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(family)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(family.opacity(0.15)))
        .accessibilityLabel(modelLabel(sp.model, effort: sp.effort))
    }
  }
}

/// Compact form of `modelLabel`: "Opus 5.5 · XH".
func modelChipText(_ model: String, effort: String) -> String {
  let name = modelLabel(model, effort: "")
  let e = ["low": "L", "medium": "M", "high": "H", "xhigh": "XH", "max": "Max"][effort] ?? ""
  return e.isEmpty ? name : "\(name) · \(e)"
}

extension Store {
  /// Running or waiting chats, then ones that finished in the last 10 minutes.
  var agentChats: [Chat] {
    let now = nowMs
    return rankedChats.filter {
      let s = $0.liveState(now: now)
      return s == .working || s == .waiting || (s == .done && now - $0.stateAt < 10 * 60_000)
    }
  }
}
