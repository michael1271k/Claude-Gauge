// Prompt notes: sticky notes for prompts you want to send later. Paste or write one, click it to copy it back.
// Saved to ~/.claude/gauge/notes.json. Nothing is sent anywhere.
import AppKit
import SwiftUI

struct Note: Codable, Identifiable, Hashable {
  var id = UUID().uuidString
  var title: String
  var subtitle = ""
  var text: String
  var color = NoteColor.yellow.rawValue
  var created = Date()

  /// First line of the text, trimmed: the default title.
  static func title(for text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    return line.count > 48 ? String(line.prefix(47)) + "…" : line.isEmpty ? "Untitled prompt" : line
  }
}

enum NoteColor: String, CaseIterable {
  case yellow, pink, mint, sky, lilac
  var color: Color {
    switch self {
    case .yellow: Color(hex: 0xFFD966)
    case .pink: Color(hex: 0xFF9EC4)
    case .mint: Color(hex: 0x7EE0B5)
    case .sky: Color(hex: 0x8CCBFF)
    case .lilac: Color(hex: 0xC3A6FF)
    }
  }
}

@MainActor @Observable final class NoteBook {
  static let shared = NoteBook()
  private let url = gaugeDir.appending(path: "notes.json")
  var notes: [Note] = []
  /// The note just copied, for the "Copied" flash.
  var copiedID: String?

  init() {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    notes = (try? dec.decode([Note].self, from: Data(contentsOf: url))) ?? []
  }

  private func save() {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = .prettyPrinted
    try? enc.encode(notes).write(to: url, options: .atomic)
  }

  /// New note from whatever text is on the clipboard; nil when it holds no text.
  @discardableResult func pasteNew() -> Note? {
    guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    let colors = NoteColor.allCases
    let n = Note(title: Note.title(for: text), text: text, color: colors[notes.count % colors.count].rawValue)
    notes.insert(n, at: 0)
    save()
    return n
  }

  func upsert(_ n: Note) {
    if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n } else { notes.insert(n, at: 0) }
    save()
  }

  func delete(_ n: Note) {
    notes.removeAll { $0.id == n.id }
    save()
  }

  func copy(_ n: Note) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(n.text, forType: .string)
    copiedID = n.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
      if self?.copiedID == n.id { self?.copiedID = nil }
    }
  }
}

/// The notes section of the Agents tab: Paste / New, then a two-column grid of sticky notes.
struct NotesSection: View {
  @State private var book = NoteBook.shared
  @State private var nothingToPaste = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        SectionLabel(text: "Prompt notes")
        Spacer()
        if nothingToPaste { Text("Clipboard has no text").font(.system(size: 10)).foregroundStyle(.tertiary).transition(.opacity) }
        IconButton(symbol: "doc.on.clipboard", hint: "Paste the clipboard as a new note") {
          if book.pasteNew() == nil {
            withAnimation { nothingToPaste = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { nothingToPaste = false } }
          }
        }
        IconButton(symbol: "square.and.pencil", hint: "Write a new note") { Windows.editNote(nil) }
      }
      .font(.system(size: 12))
      if book.notes.isEmpty {
        Text("Save prompts for later: copy text anywhere, then paste it here. Click a note to copy it back.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
      } else {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
          ForEach(book.notes) { StickyNote(note: $0, book: book) }
        }
      }
    }
  }
}

struct StickyNote: View {
  let note: Note
  let book: NoteBook
  @State private var hover = false

  var body: some View {
    let tint = NoteColor(rawValue: note.color)?.color ?? NoteColor.yellow.color
    let copied = book.copiedID == note.id
    VStack(alignment: .leading, spacing: 3) {
      Text(note.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
      if !note.subtitle.isEmpty { Text(note.subtitle).font(.system(size: 10, weight: .medium)).opacity(0.7).lineLimit(1) }
      Text(note.text).font(.system(size: 10)).opacity(0.62).lineLimit(3)
      Spacer(minLength: 0)
      HStack(spacing: 4) {
        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .bold))
        Text(copied ? "Copied" : "Click to copy").font(.system(size: 9.5, weight: .semibold))
      }
      .opacity(hover || copied ? 0.9 : 0)
    }
    .foregroundStyle(Color(white: 0.1))
    .padding(9)
    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(hover ? 1 : 0.92)))
    .overlay(alignment: .topTrailing) {
      if hover {
        HStack(spacing: 2) {
          mini("pencil", "Edit") { Windows.editNote(note) }
          mini("trash", "Delete") { withAnimation(widgetSpring) { book.delete(note) } }
        }
        .padding(4)
      }
    }
    .rotationEffect(.degrees(hover ? 0 : (note.id.hashValue % 2 == 0 ? -0.8 : 0.8)))
    .scaleEffect(copied ? 0.97 : 1)
    .animation(widgetSpring, value: hover)
    .animation(widgetSpring, value: copied)
    .contentShape(Rectangle())
    .onTapGesture { book.copy(note) }
    .onHover { hover = $0 }
    .contextMenu {
      Button("Copy prompt") { book.copy(note) }
      Button("Edit…") { Windows.editNote(note) }
      Menu("Color") {
        ForEach(NoteColor.allCases, id: \.self) { c in
          Button(c.rawValue.capitalized) { var n = note; n.color = c.rawValue; book.upsert(n) }
        }
      }
      Divider()
      Button("Delete", role: .destructive) { book.delete(note) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Copies the prompt")
  }

  private func mini(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) {
      Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Color(white: 0.15))
        .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.55)))
    }
    .buttonStyle(.plain).accessibilityLabel(label)
  }
}

/// Edits one note in a small real window (the widget never takes keyboard focus).
struct NoteEditor: View {
  @State var note: Note
  let isNew: Bool
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Title", text: $note.title).textFieldStyle(.roundedBorder).font(.system(size: 13, weight: .semibold))
      TextField("Subtitle (optional): project, when to use it…", text: $note.subtitle).textFieldStyle(.roundedBorder)
      TextEditor(text: $note.text)
        .font(.system(size: 12))
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.14)))
        .frame(minHeight: 160)
      HStack(spacing: 8) {
        ForEach(NoteColor.allCases, id: \.self) { c in
          Circle().fill(c.color).frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.white, lineWidth: note.color == c.rawValue ? 2 : 0))
            .onTapGesture { note.color = c.rawValue }
            .accessibilityLabel(c.rawValue.capitalized)
            .accessibilityAddTraits(note.color == c.rawValue ? [.isButton, .isSelected] : .isButton)
        }
        Spacer()
        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        Button(isNew ? "Save note" : "Save") {
          if note.title.trimmingCharacters(in: .whitespaces).isEmpty { note.title = Note.title(for: note.text) }
          NoteBook.shared.upsert(note)
          close()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .frame(minWidth: 420, minHeight: 320)
    .tint(Palette.accent)
  }
}
