import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// Best-effort detection of shortcuts already claimed elsewhere on the machine.
///
/// macOS only exposes *system* symbolic hot keys (Mission Control, screenshots,
/// Spotlight, input-source switching, …) via `CopySymbolicHotKeys`. There is no
/// API to enumerate other applications' shortcuts, so purely in-app shortcuts
/// like VS Code's ⌘⇧P cannot be detected — this covers what the OS reports.
///
/// The recorder in settings additionally validates at record time (the
/// KeyboardShortcuts library alerts on system and app-menu conflicts); this
/// helper exists for *stored* shortcuts, so conflicts that predate that
/// validation still surface as a warning in settings.
nonisolated enum SystemShortcuts {
    struct Combo: Hashable {
        var keyCode: Int
        var carbonModifiers: Int
    }

    /// Currently enabled system symbolic hot keys.
    static func enabledSystemCombos() -> Set<Combo> {
        var hotKeysRef: Unmanaged<CFArray>?
        guard
            CopySymbolicHotKeys(&hotKeysRef) == noErr,
            let hotKeys = hotKeysRef?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        var combos: Set<Combo> = []
        for entry in hotKeys {
            guard
                (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                let keyCode = entry[kHISymbolicHotKeyCode] as? Int,
                let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int
            else { continue }
            combos.insert(Combo(keyCode: keyCode, carbonModifiers: modifiers))
        }
        return combos
    }

    static func conflictsWithSystem(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        conflicts(shortcut, against: enabledSystemCombos())
    }

    /// Pure core, injectable for tests.
    static func conflicts(
        _ shortcut: KeyboardShortcuts.Shortcut,
        against combos: Set<Combo>
    ) -> Bool {
        combos.contains(Combo(keyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers))
    }

    /// Warning text for settings, or nil when no conflict is known.
    static func conflictWarning(for shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut, conflictsWithSystem(shortcut) else { return nil }
        return "\(shortcut) is also a macOS system shortcut. One of the two will not work; consider a different combination."
    }
}
