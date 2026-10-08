// Prompt Pad: sticky notes for prompts you want to send later, in their own floating window.
// Click a note to edit it in place, the copy button copies it, drag to reorder. Saved to ~/.claude/gauge/notes.json.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Note: Codable, Identifiable, Hashable {
  var id = UUID().uuidString
  var title = ""
  var subtitle = ""
  var text = ""
  var color = NoteColor.yellow.rawValue
  var created = Date()

  /// First line of the text, trimmed: shown when the note has no title.
  var displayTitle: String {
    if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    return line.isEmpty ? "New note" : line
  }
}

enum NoteColor: String, CaseIterable {
  case yellow, pink, mint, sky, lilac, peach
  var color: Color {
    switch self {
    case .yellow: Color(hex: 0xFFD966)
    case .pink: Color(hex: 0xFF9EC4)
    case .mint: Color(hex: 0x7EE0B5)
    case .sky: Color(hex: 0x8CCBFF)
    case .lilac: Color(hex: 0xC3A6FF)
    case .peach: Color(hex: 0xFFB38A)
    }
  }
}

@MainActor @Observable final class NoteBook {
  static let shared = NoteBook()
  private let url = gaugeDir.appending(path: "notes.json")
  var notes: [Note] = []
  var editingID: String?
  var copiedID: String?
  var sentID: String?
  var sentTo = ""

  init() {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    notes = (try? dec.decode([Note].self, from: Data(contentsOf: url))) ?? []
  }

  func save() {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = .prettyPrinted
    try? enc.encode(notes).write(to: url, options: .atomic)
  }

  /// An empty note in a random color, opened for editing.
  func addEmpty() {
    let n = Note(color: NoteColor.allCases.randomElement()!.rawValue)
    notes.insert(n, at: 0)
    editingID = n.id
    save()
  }

  /// A note holding the clipboard's text; false when the clipboard has none.
  func paste() -> Bool {
    guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
    notes.insert(Note(text: text, color: NoteColor.allCases.randomElement()!.rawValue), at: 0)
    save()
    return true
  }

  func delete(_ id: String) {
    notes.removeAll { $0.id == id }
    if editingID == id { editingID = nil }
    save()
  }

  func copy(_ n: Note) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(n.text, forType: .string)
    copiedID = n.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      if self?.copiedID == n.id { self?.copiedID = nil }
    }
  }

  /// Hands a note to a chat: `send` submits it as you, `draft` puts it in that chat's prompt box. The chat's
  /// usage-gauge plugin picks it up within 2 s while the chat is open (or as soon as it opens), then the chat comes forward.
  func deliver(_ n: Note, to chat: Chat, draft: Bool) {
    let dir = gaugeDir.appending(path: "inbox")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let msg: [String: Any] = ["text": n.text, "mode": draft ? "draft" : "send", "at": Date().timeIntervalSince1970 * 1000, "handled": false]
    if let data = try? JSONSerialization.data(withJSONObject: msg) { try? data.write(to: dir.appending(path: "\(chat.id).json"), options: .atomic) }
    sentID = n.id
    sentTo = chat.displayTitle
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      if self?.sentID == n.id { self?.sentID = nil }
    }
    openChat(chat)
  }

  /// Puts note `id` where `target` is.
  func move(_ id: String, to target: String) {
    guard id != target, let from = notes.firstIndex(where: { $0.id == id }), let to = notes.firstIndex(where: { $0.id == target }) else { return }
    notes.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    save()
  }
}

/// Prompt Pad layouts: a grid of cards, a compact list, or one horizontal strip.
enum PadLayout: String, CaseIterable {
  case grid = "Grid", list = "List", strip = "Strip"
  var symbol: String {
    switch self {
    case .grid: "square.grid.2x2"
    case .list: "list.bullet"
    case .strip: "rectangle.split.3x1"
    }
  }
}

/// The Prompt Pad window: translucent like a Mac utility window, a slim title bar with search and layout,
/// cards that lift under the pointer.
struct PromptPad: View {
  @State private var book = NoteBook.shared
  @State private var query = ""
  @State private var nothingToPaste = false
  @AppStorage("theme") private var theme = "Sunset"
  @AppStorage("padLayout") private var layoutRaw = PadLayout.grid.rawValue
  private var layout: PadLayout { PadLayout(rawValue: layoutRaw) ?? .grid }

  private var shown: [Note] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return book.notes }
    return book.notes.filter { ($0.title + " " + $0.subtitle + " " + $0.text).lowercased().contains(q) }
  }

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      Divider().opacity(0.35)
      Group {
        if book.notes.isEmpty {
          emptyState
        } else if shown.isEmpty {
          Text("No notes match “\(query)”").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          switch layout {
          case .grid:
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) { cards(compact: false) }.padding(14) }
          case .list:
            ScrollView { LazyVStack(spacing: 8) { cards(compact: true) }.padding(14) }
          case .strip:
            ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { cards(compact: false, width: 190) }.padding(14) }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(VisualEffect().ignoresSafeArea())
    .frame(minWidth: 420, minHeight: 300)
    .tint(Palette.accent)
    .id(theme)
  }

  private var titleBar: some View {
    HStack(spacing: 10) {
      Text("Prompt Pad").font(.system(size: 13, weight: .semibold)).tracking(-0.1)
      Spacer(minLength: 8)
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
        TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 12)).frame(width: 110)
      }
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
      Picker("Layout", selection: $layoutRaw) {
        ForEach(PadLayout.allCases, id: \.self) { Image(systemName: $0.symbol).help($0.rawValue).tag($0.rawValue) }
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      Button {
        if !withAnimation(widgetSpring, { book.paste() }) {
          nothingToPaste = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nothingToPaste = false }
        }
      } label: {
        Image(systemName: nothingToPaste ? "exclamationmark.circle" : "doc.on.clipboard").font(.system(size: 12, weight: .medium))
          .frame(width: 26, height: 24)
      }
      .buttonStyle(.borderless).help(nothingToPaste ? "The clipboard has no text" : "New note from the clipboard")
      Button { withAnimation(widgetSpring) { book.addEmpty() } } label: {
        Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
          .frame(width: 24, height: 24).background(Circle().fill(Palette.accent))
      }
      .buttonStyle(.plain).help("New note").accessibilityLabel("New note").keyboardShortcut("n")
    }
    .padding(.leading, 78) // clear of the window's close button
    .padding(.trailing, 12)
    .frame(height: 40)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "note.text").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent)
      Text("Keep prompts for later").font(.system(size: 14, weight: .semibold))
      Text("Click + for a new note, or copy a prompt anywhere and use the clipboard button.")
        .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 260)
    }
  }

  /// Every shown note, draggable onto another to take its place.
  @ViewBuilder private func cards(compact: Bool, width: CGFloat? = nil) -> some View {
    ForEach(shown) { note in
      StickyNote(note: note, book: book, compact: compact)
        .frame(width: width)
        .draggable(note.id) { StickyNote(note: note, book: book, compact: compact).frame(width: 170).opacity(0.9) }
        .dropDestination(for: String.self) { ids, _ in
          guard let id = ids.first else { return false }
          withAnimation(widgetSpring) { book.move(id, to: note.id) }
          return true
        }
    }
  }
}

/// The window's material, behind everything (a real Mac vibrancy view).
struct VisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    return v
  }
  func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct StickyNote: View {
  let note: Note
  let book: NoteBook
  /// List layout: one line of text, shorter card.
  var compact = false
  @State private var hover = false
  @FocusState private var focused: Bool

  private var editing: Bool { book.editingID == note.id }
  private var binding: Binding<Note> {
    Binding(get: { book.notes.first { $0.id == note.id } ?? note }, set: { n in
      if let i = book.notes.firstIndex(where: { $0.id == n.id }) { book.notes[i] = n }
    })
  }

  var body: some View {
    let tint = NoteColor(rawValue: note.color)?.color ?? NoteColor.yellow.color
    VStack(alignment: .leading, spacing: 4) {
      if editing { editor } else { preview }
    }
    .foregroundStyle(Color(white: 0.12))
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: compact && !editing ? 46 : 96, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
    )
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
    .overlay(alignment: .topTrailing) { if !editing { cornerButtons } }
    .overlay(alignment: .bottomLeading) {
      if book.sentID == note.id {
        Label("Sent to \(book.sentTo)", systemImage: "paperplane.fill").font(.system(size: 9.5, weight: .bold))
          .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(.white.opacity(0.75))).padding(6)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .shadow(color: .black.opacity(hover || editing ? 0.32 : 0.18), radius: hover || editing ? 10 : 4, y: hover || editing ? 5 : 2)
    .scaleEffect(hover && !editing ? 1.015 : 1)
    .animation(.spring(response: 0.3, dampingFraction: 1), value: hover)
    .animation(widgetSpring, value: editing)
    .animation(widgetSpring, value: book.sentID)
    .contentShape(Rectangle())
    .onTapGesture { if !editing { book.editingID = note.id } }
    .onHover { hover = $0 }
    .contextMenu {
      Button("Copy") { book.copy(note) }
      Button("Edit") { book.editingID = note.id }
      sendMenu
      Divider()
      Button("Delete", role: .destructive) { withAnimation(widgetSpring) { book.delete(note.id) } }
    }
  }

  private var cornerButtons: some View {
    HStack(spacing: 3) {
      if hover {
        Menu { sendMenu } label: { circle("paperplane") }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Send to a chat")
        Button { withAnimation(widgetSpring) { book.delete(note.id) } } label: { circle("trash") }
          .buttonStyle(.plain).help("Delete").accessibilityLabel("Delete note")
      }
      Button { book.copy(note) } label: { circle(book.copiedID == note.id ? "checkmark" : "doc.on.doc") }
        .buttonStyle(.plain).help("Copy").accessibilityLabel("Copy prompt")
    }
    .padding(5)
  }

  /// Running and recent chats first.
  @ViewBuilder private var sendMenu: some View {
    let chats = Array((Windows.store?.rankedChats ?? []).prefix(8))
    Menu("Send to chat") {
      if chats.isEmpty { Text("No chats yet") }
      ForEach(chats) { c in Button(c.displayTitle) { book.deliver(note, to: c, draft: false) } }
    }
    Menu("Put in a chat's prompt box") {
      ForEach(chats) { c in Button(c.displayTitle) { book.deliver(note, to: c, draft: true) } }
    }
  }

  private func circle(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Color(white: 0.15))
      .frame(width: 21, height: 21).background(Circle().fill(.white.opacity(hover ? 0.75 : 0.5)))
  }

  @ViewBuilder private var preview: some View {
    Text(note.displayTitle).font(.system(size: 12.5, weight: .semibold)).tracking(-0.1).lineLimit(compact ? 1 : 2)
      .padding(.trailing, hover ? 74 : 26)
    if !note.subtitle.isEmpty { Text(note.subtitle).font(.system(size: 10.5, weight: .medium)).opacity(0.65).lineLimit(1) }
    if !note.text.isEmpty {
      Text(note.text).font(.system(size: 11)).lineSpacing(1.5).opacity(0.72).lineLimit(compact ? 1 : 4)
    }
  }

  @ViewBuilder private var editor: some View {
    TextField("Title", text: binding.title).font(.system(size: 12.5, weight: .semibold)).textFieldStyle(.plain)
    TextField("Subtitle", text: binding.subtitle).font(.system(size: 10.5, weight: .medium)).textFieldStyle(.plain).opacity(0.75)
    TextEditor(text: binding.text)
      .font(.system(size: 11)).scrollContentBackground(.hidden).focused($focused)
      .frame(minHeight: 80)
      .padding(4)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.4)))
    HStack(spacing: 5) {
      ForEach(NoteColor.allCases, id: \.self) { c in
        Circle().fill(c.color).frame(width: 14, height: 14)
          .overlay(Circle().strokeBorder(Color(white: 0.15), lineWidth: note.color == c.rawValue ? 1.5 : 0.5))
          .onTapGesture { binding.wrappedValue.color = c.rawValue }
          .accessibilityLabel(c.rawValue.capitalized)
      }
      Spacer()
      Button { withAnimation(widgetSpring) { book.delete(note.id) } } label: { Image(systemName: "trash").font(.system(size: 10, weight: .semibold)) }
        .buttonStyle(.plain).help("Delete").accessibilityLabel("Delete note")
      Button("Done") {
        book.editingID = nil
        book.save()
      }
      .buttonStyle(.plain).font(.system(size: 11, weight: .bold))
      .keyboardShortcut(.defaultAction)
    }
    .onAppear { focused = true }
  }
}
