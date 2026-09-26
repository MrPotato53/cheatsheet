import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import Testing

@testable import Cheatsheet

struct SystemShortcutsTests {
    @Test func shortcutMapsToCarbonComboCorrectly() {
        // ⌘⇧3 — kVK_ANSI_3 with cmdKey|shiftKey, the screenshot shortcut.
        let shortcut = KeyboardShortcuts.Shortcut(.three, modifiers: [.command, .shift])
        let combos: Set<SystemShortcuts.Combo> = [
            .init(keyCode: kVK_ANSI_3, carbonModifiers: cmdKey | shiftKey)
        ]
        #expect(SystemShortcuts.conflicts(shortcut, against: combos))
    }

    @Test func differentKeyOrModifiersDoNotConflict() {
        let combos: Set<SystemShortcuts.Combo> = [
            .init(keyCode: kVK_ANSI_3, carbonModifiers: cmdKey | shiftKey)
        ]
        #expect(!SystemShortcuts.conflicts(
            KeyboardShortcuts.Shortcut(.four, modifiers: [.command, .shift]),
            against: combos
        ))
        #expect(!SystemShortcuts.conflicts(
            KeyboardShortcuts.Shortcut(.three, modifiers: [.command]),
            against: combos
        ))
        #expect(!SystemShortcuts.conflicts(
            KeyboardShortcuts.Shortcut(.three, modifiers: [.command, .shift, .option]),
            against: combos
        ))
    }

    @Test func conflictWarningOnlyForConflictingShortcuts() {
        #expect(SystemShortcuts.conflictWarning(for: nil) == nil)
        // ⌃⌥⌘⇧M is claimed by no macOS symbolic hot key.
        let obscure = KeyboardShortcuts.Shortcut(.m, modifiers: [.command, .shift, .option, .control])
        #expect(SystemShortcuts.conflictWarning(for: obscure) == nil)
    }

    /// Runs on a real Mac (hosted in the app), where the OS always reports
    /// symbolic hot keys; empty means the CopySymbolicHotKeys plumbing broke.
    @Test func systemReportsEnabledHotKeys() {
        #expect(!SystemShortcuts.enabledSystemCombos().isEmpty)
    }
}
