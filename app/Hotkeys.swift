// Global shortcuts that work from any app, without Accessibility permission (Carbon hot keys):
// ⌥⌘G shows or hides Claude Gauge, ⌥⌘P opens the Prompt Pad.
import Carbon
import Foundation

@MainActor final class Hotkeys {
  static let shared = Hotkeys()
  private var refs: [EventHotKeyRef?] = []
  fileprivate var actions: [UInt32: () -> Void] = [:]

  func install(gauge: @escaping () -> Void, pad: @escaping () -> Void) {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hk = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hk)
      let n = hk.id
      DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.actions[n]?() } }
      return noErr
    }, 1, &spec, nil, nil)
    register(1, kVK_ANSI_G, gauge)
    register(2, kVK_ANSI_P, pad)
  }

  private func register(_ n: UInt32, _ key: Int, _ action: @escaping () -> Void) {
    actions[n] = action
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey), EventHotKeyID(signature: OSType(0x4741_5547), id: n),
                        GetApplicationEventTarget(), 0, &ref)
    refs.append(ref)
  }
}
