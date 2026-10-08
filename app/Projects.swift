// The Projects tab: what each project (a chat's folder) cost this week, today, and over the last 14 days.
import SwiftUI

struct ProjectsView: View {
  let store: Store
  var body: some View {
    let start = Store.calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
    let projects = store.projects(since: start)
    let top = projects.first?.usd ?? 1
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionLabel(text: "This week by project")
        Spacer()
        Text("14 days").font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
      }
      if projects.isEmpty {
        Text("Projects show up here once their chats have spent something this week.")
          .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 10)
      }
      ForEach(projects.prefix(8)) { p in
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(p.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Text("\(p.chats) chat\(p.chats == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            Sparkline(values: p.daily).frame(width: 70, height: 16)
            Text(Format.money(p.usd)).font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
              .foregroundStyle(Palette.accent).frame(minWidth: 54, alignment: .trailing)
          }
          GeometryReader { g in
            Capsule().fill(LinearGradient(colors: [Palette.accent.opacity(0.5), Palette.secondary], startPoint: .leading, endPoint: .trailing))
              .frame(width: max(4, g.size.width * p.usd / top))
          }
          .frame(height: 4)
          if p.today > 0 {
            Text("\(Format.money(p.today)) today").font(.system(size: 10)).foregroundStyle(Palette.secondary.opacity(0.9))
          }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// Tiny bar chart, newest on the right, today highlighted.
struct Sparkline: View {
  let values: [Double]
  var body: some View {
    let top = max(values.max() ?? 0, 0.01)
    HStack(alignment: .bottom, spacing: 1.5) {
      ForEach(values.indices, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1)
          .fill(i == values.count - 1 ? Palette.secondary : Palette.accent.opacity(0.55))
          .frame(height: max(1.5, 16 * values[i] / top))
      }
    }
    .accessibilityHidden(true)
  }
}
