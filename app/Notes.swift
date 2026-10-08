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

  /// Puts note `id` where `target` is.
  func move(_ id: String, to target: String) {
    guard id != target, let from = notes.firstIndex(where: { $0.id == id }), let to = notes.firstIndex(where: { $0.id == target }) else { return }
    notes.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    save()
  }
}

/// The Prompt Pad window's content.
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

struct PromptPad: View {
  @State private var book = NoteBook.shared
  @State private var nothingToPaste = false
  @AppStorage("theme") private var theme = "Ocean"
  @AppStorage("padLayout") private var layoutRaw = PadLayout.grid.rawValue
  private var layout: PadLayout { PadLayout(rawValue: layoutRaw) ?? .grid }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Picker("Layout", selection: $layoutRaw) {
          ForEach(PadLayout.allCases, id: \.self) { Image(systemName: $0.symbol).help($0.rawValue).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 104)
        Text("\(book.notes.count) note\(book.notes.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        if nothingToPaste { Text("Nothing to paste").font(.system(size: 10)).foregroundStyle(.tertiary) }
        IconButton(symbol: "doc.on.clipboard", hint: "New note from the clipboard") {
          if !withAnimation(widgetSpring, { book.paste() }) {
            nothingToPaste = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nothingToPaste = false }
          }
        }
        .font(.system(size: 12))
        Button { withAnimation(widgetSpring) { book.addEmpty() } } label: {
          Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
            .background(Circle().fill(Palette.accent)).foregroundStyle(.black)
        }
        .buttonStyle(.plain).help("New note").accessibilityLabel("New note")
      }
      if book.notes.isEmpty {
        Text("Click + for a new note, or copy a prompt anywhere and use the clipboard button.")
          .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
        Spacer()
      }
      switch layout {
      case .grid:
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) { notes(compact: false) }.padding(2)
        }
      case .list:
        ScrollView { LazyVStack(spacing: 6) { notes(compact: true) }.padding(2) }
      case .strip:
        ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 8) { notes(compact: false, width: 170) }.padding(2) }
      }
    }
    .padding(12)
    .frame(minWidth: 340, minHeight: 240)
    .tint(Palette.accent)
    .id(theme)
  }
}

extension PromptPad {
  /// Every note, draggable onto another to take its place.
  @ViewBuilder func notes(compact: Bool, width: CGFloat? = nil) -> some View {
    ForEach(book.notes) { note in
      StickyNote(note: note, book: book, compact: compact)
        .frame(width: width)
        .draggable(note.id) { StickyNote(note: note, book: book, compact: compact).frame(width: 160).opacity(0.85) }
        .dropDestination(for: String.self) { ids, _ in
          guard let id = ids.first else { return false }
          withAnimation(widgetSpring) { book.move(id, to: note.id) }
          return true
        }
    }
  }
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
    VStack(alignment: .leading, spacing: 3) {
      if editing { editor } else { preview }
    }
    .foregroundStyle(Color(white: 0.1))
    .padding(8)
    .frame(maxWidth: .infinity, minHeight: compact && !editing ? 44 : 78, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(hover || editing ? 1 : 0.9)))
    .overlay(alignment: .topTrailing) {
      if !editing {
        HStack(spacing: 3) {
          if hover {
            corner("trash", "Delete note") { withAnimation(widgetSpring) { book.delete(note.id) } }
          }
          corner(book.copiedID == note.id ? "checkmark" : "doc.on.doc", "Copy prompt") { book.copy(note) }
        }
        .padding(4)
      }
    }
    .shadow(color: .black.opacity(editing ? 0.35 : 0), radius: 8, y: 3)
    .contentShape(Rectangle())
    .onTapGesture { if !editing { book.editingID = note.id } }
    .onHover { hover = $0 }
    .contextMenu {
      Button("Copy") { book.copy(note) }
      Button("Edit") { book.editingID = note.id }
      Divider()
      Button("Delete", role: .destructive) { withAnimation(widgetSpring) { book.delete(note.id) } }
    }
    .animation(widgetSpring, value: editing)
  }

  private func corner(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) {
      Image(systemName: symbol).font(.system(size: 9, weight: .bold))
        .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(hover ? 0.7 : 0.45)))
    }
    .buttonStyle(.plain).foregroundStyle(Color(white: 0.15))
    .help(label).accessibilityLabel(label)
  }

  @ViewBuilder private var preview: some View {
    Text(note.displayTitle).font(.system(size: 11.5, weight: .semibold)).lineLimit(compact ? 1 : 2).padding(.trailing, 46)
    if !note.subtitle.isEmpty { Text(note.subtitle).font(.system(size: 10, weight: .medium)).opacity(0.7).lineLimit(1) }
    if !note.text.isEmpty { Text(note.text).font(.system(size: 10)).opacity(0.65).lineLimit(compact ? 1 : 3) }
  }

  @ViewBuilder private var editor: some View {
    TextField("Title", text: binding.title).font(.system(size: 11.5, weight: .semibold)).textFieldStyle(.plain)
    TextField("Subtitle", text: binding.subtitle).font(.system(size: 10, weight: .medium)).textFieldStyle(.plain).opacity(0.75)
    TextEditor(text: binding.text)
      .font(.system(size: 10.5)).scrollContentBackground(.hidden).focused($focused)
      .frame(minHeight: 70)
      .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.35)))
    HStack(spacing: 5) {
      ForEach(NoteColor.allCases, id: \.self) { c in
        Circle().fill(c.color).frame(width: 13, height: 13)
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
      .buttonStyle(.plain).font(.system(size: 10.5, weight: .bold))
      .keyboardShortcut(.defaultAction)
    }
    .onAppear { focused = true }
  }
}
