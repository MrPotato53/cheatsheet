# UI Testing

The UI test suite lives in `CheatsheetUITests/` and drives the real app —
menu bar extra, settings window, and overlay panels — via XCUITest plus a
small DEBUG-only introspection channel.

## Running

```sh
xcodebuild test \
  -project Cheatsheet.xcodeproj \
  -scheme Cheatsheet \
  -destination 'platform=macOS'
```

or `⌘U` in Xcode. Notes:

- Run on a machine (or CI runner) where the test runner has **Accessibility /
  Automation permission** — XCUITest synthesizes real clicks, drags, and
  keystrokes. The very first run may prompt.
- Tests move the mouse and open windows; don't use the machine while the
  suite runs. Drag/snap tests in particular are sensitive to a fighting user.
- Every test launches the app hermetically: a throwaway library root in the
  app container's temp dir, an isolated `UserDefaults` suite that is wiped at
  launch, and stubbed launch-at-login registration. Your real cheatsheets,
  settings, and login items are never read or written.

## How the harness works

UI tests can't reach into a sandboxed menu-bar app, so the app exposes
DEBUG-only hooks (all inert in release builds):

- **`CHEATSHEET_TEST_RUN`** (env): activates test mode; the library root
  moves to a run-scoped temp dir inside the sandbox container.
- **`CHEATSHEET_TEST_SEED`** (env): JSON describing cheatsheets to seed. The
  app generates the media itself (solid-color PNGs at exact pixel sizes, text
  files) because the sandbox prevents the runner from writing fixtures.
  Built by `SeedSheet`/`SeedPage` in the test target.
- **`CHEATSHEET_TEST_DEFAULTS`** (env): JSON of initial defaults (e.g.
  `{"dockIconPolicy": "always", "dismissWithEsc": false}`) applied to the
  isolated suite before the UI loads.
- **Debug driver** (`potatodev.cheatsheet.debug` distributed notification,
  pre-existing): extended with `dockReopen` (drives the Dock-click delegate
  path), `keyDown:N` / `keyUp:N` (drives the hotkey handlers below the Carbon
  layer, which can't be synthesized), and `state:<nonce>`.
- **State channel** (`potatodev.cheatsheet.debug.state`): replies to
  `state:<nonce>` with a JSON snapshot — activation policy, settings window
  visibility/key status, overlay sessions (page index/count, pin, panel frame
  and screen visible frame in AppKit coordinates), and persisted per-sheet
  config. Tests assert against this instead of scraping accessibility frames.
- **Run scoping**: distributed notifications broadcast to *every* process, so
  any other DEBUG build on the machine (e.g. the app run straight from Xcode)
  also answers this channel. Left unscoped, its empty state snapshot races and
  clobbers the real one, and its windows respond to `dockReopen`. So in test
  mode the runner tags every command `command@@<runID>` and the app acts only
  on its own run; state replies also carry `runID` and the runner drops any
  that don't match. Tests are therefore robust to a stray DEBUG instance —
  but LaunchServices `open` still can't disambiguate two apps that share a
  bundle ID, so `reopenFromDock` may target the wrong one; prefer the
  `dockReopen` debug action, and don't leave a second instance running.

Real Dock-icon clicks are simulated by `open`-ing the running app bundle,
which delivers the same reopen Apple event through LaunchServices.

## Suites

| File | Covers |
| --- | --- |
| `CheatsheetUITests.swift` | Launch smoke: accessory policy, no windows, menu contents, launch perf |
| `SettingsWindowUITests.swift` | Settings opens from menu bar; refocus when already open (menu bar and Dock); Dock click opens settings when no windows visible; Dock icon policy transitions on close |
| `OverlayUITests.swift` | Opening a cheatsheet from the menu; paging (buttons + arrow keys); Escape dismissal on/off; pinning; transient-vs-pinned sessions; hold-to-show; empty sheet placeholder; text/markdown pages |
| `SettingsBehaviorUITests.swift` | Every setting's outcome: Dock icon policy picker, Escape toggle, launch-at-login toggle (stubbed), rename, activation mode, start page (first/last-viewed/fixed), size slider (live + persisted), position preview drag + Center, drag behavior locked/resets/remembers, resize behavior locked/remembers, delete |
| `EdgeSnapUITests.swift` | Drag past screen edges → snap back fully on-screen; edge contact (top, side, corner) preserved across page aspect-ratio changes and across reopen |

## Known limitations

- **Edge-stick across aspect changes**: `EdgeSnapUITests` asserts the overlay
  keeps hugging an edge when the page aspect changes. This is implemented:
  when a drag/resize drops the panel against an edge, `normalizedCenter`
  saturates that axis to 0/1 so the stored position pins to the edge for every
  page size (see `OverlayController`), rather than storing a proportional
  center that drifts inward once a narrower page is shown.
- **File import** (`NSOpenPanel`) is a remote view service XCUITest cannot
  drive; adding files is covered by seeding + the store unit tests. Manual
  test: sidebar `+`, drag-and-drop onto the sidebar.
- **Global hotkeys** (Carbon layer) and the KeyboardShortcuts recorder are
  not automated; handlers below them are covered via `keyDown:N`/`keyUp:N`.
- **Multi-monitor targeting** (`DisplayTarget.specific`, cursor/focused
  screen) needs hardware with two displays; not asserted in CI.
- Page-gallery drag reordering, hide/unhide, and rotation are covered by unit
  tests (`CheatsheetTests`), not UI automation.
