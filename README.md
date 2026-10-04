# Cheatsheet

A macOS menu bar app that keeps your reference material one keystroke away.
Put keyboard shortcut lists, command references, notes, diagrams, or docs
into cheatsheets, then pop any of them up over whatever you're doing, read,
and dismiss.

## What it does

- **As many cheatsheets as you want.** Each one is a stack of pages: Vim
  keys, a Git reference, your team's runbook, a screenshot of a keyboard
  layout.
- **Open them instantly.** Give each cheatsheet its own keyboard shortcut,
  or open any of them from a Spotlight-style search bar. A shortcut can
  toggle the cheatsheet or show it only while you hold the keys.
- **Bring almost any file.** PDFs (one page per PDF page), images, markdown
  (with tables, checklists, code blocks, and Mermaid diagrams), HTML
  pages, and plain text or source files. Live web pages work too.
- **Search inside them.** ⌘F finds text across a cheatsheet's pages,
  including text in images and PDFs and in web pages that have loaded.
- **Edit in place.** Fix a typo or tick off a checklist item right in the
  cheatsheet. Optionally keep each page in sync with the original file it
  came from; if both changed, you choose which version to keep.
- **Put it where you want.** Choose the screen, size, and position for each
  cheatsheet. Pin one to keep it open while you work, or let it close when
  you click away or press Escape.

## Requirements

- macOS 26 or later
- To build: Xcode 26

## Install

There are no prebuilt releases yet, so build it from source:

1. Clone this repository and open `Cheatsheet.xcodeproj` in Xcode.
2. Select the **Cheatsheet** target, then **Signing & Capabilities**, and
   choose your own team (a free Apple ID works).
3. Run it (⌘R), or build a release copy with `./build.sh`, which produces
   `build/Build/Products/Release/Cheatsheet.app`. Move that app to
   `/Applications`.

Cheatsheet lives in the menu bar; it has no Dock icon unless you turn one on.

## Getting started

1. Click the Cheatsheet icon in the menu bar and choose **Settings…**.
2. In **Cheatsheets**, click **+** to create one, then add files with
   **Add Files…** (or drag them in) or a web page with **Add Web Page…**.
3. Record a **Shortcut** for it.
4. Press the shortcut anywhere. Press it again, or Escape, to close.

To open cheatsheets by name instead, go to **General** and set
**Open cheatsheets with** to include the search bar (default shortcut ⇧⌘Space).

## Handy keys

These work while a cheatsheet is open:

| Keys | Does |
| --- | --- |
| ← → | Previous / next page |
| ⌘F | Search the cheatsheet (Return or ⌘G for the next match) |
| ⌘E | Edit the page (text, markdown, and HTML) |
| ⇧⌘P | Pin or unpin, so it stays open |
| Escape | Close search, finish editing, or close the cheatsheet |

All shortcuts can be changed in Settings.

## Your files

Files you add are copied into Cheatsheet's own library, so moving or
deleting the originals doesn't break anything. With **Sync with original
files** on (General settings), copies follow changes to their originals and
your edits save back. Originals are never overwritten without asking.

Web pages load from the internet when first shown and stay loaded after that.
Links to other sites open in your browser.

To move your setup to another Mac, use **Export All Cheatsheets…** in
Settings, then **Import Cheatsheets…** on the other Mac.

## Development

```sh
./test.sh        # unit tests (fast; also run by the pre-commit hook)
./test.sh full   # unit + UI tests (drives the real app; don't use the Mac meanwhile)
./build.sh       # release build, zipped as Cheatsheet.zip
```

Enable the pre-commit hook with `git config core.hooksPath .githooks`.
See [docs/ui-testing.md](docs/ui-testing.md) for how the UI tests work and
[docs/](docs/) for design notes.

## License

MIT; see [LICENSE](LICENSE). Bundled and linked open-source software is
listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
