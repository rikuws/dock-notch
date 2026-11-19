import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut, ⌃⌥M by default, that opens and closes the morning window from
/// any app. Carbon's hot keys need no Accessibility or Input Monitoring permission.
@MainActor
final class MorningHotKey {
    /// What the right-click menu shows beside Good Morning.
    static let keyEquivalent = "m"
    static let modifiers: NSEvent.ModifierFlags = [.control, .option]

    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register() {
        guard MorningSettings.hotKey, hotKey == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<MorningHotKey>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, context, &handler)

        let id = EventHotKeyID(signature: OSType(0x444E_4D4E), id: 1) // "DNMN"
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
