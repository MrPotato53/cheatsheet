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

## Install

Requires macOS 26 or later.

1. Download **Cheatsheet-x.y.z.zip** from the
   [latest release](https://github.com/MrPotato53/cheatsheet/releases/latest)
   and unzip it.
2. Move **Cheatsheet.app** to your Applications folder and open it.
3. The first time, macOS says it can't check the app for malicious software.
   That's because it isn't notarized by Apple (which needs a paid developer
   account), not because anything is wrong. Open **System Settings → Privacy
   & Security**, scroll down, and click **Open Anyway** next to Cheatsheet.
   You only do this once.

Cheatsheet lives in the menu bar; it has no Dock icon unless you turn one on.
To update, download the newer release and replace the app; your cheatsheets
and settings stay. If macOS asks whether Cheatsheet may access its data,
allow it.

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

Building needs Xcode 26. Open `Cheatsheet.xcodeproj`, choose your own team
under the **Cheatsheet** target's **Signing & Capabilities** (a free Apple ID
works), and run (⌘R).

```sh
./test.sh                    # unit tests (fast; also run by the pre-commit hook)
./test.sh full               # unit + UI tests (drives the real app; don't use the Mac meanwhile)
./build.sh                   # local release build, zipped as Cheatsheet.zip
./release.sh 1.0.0           # build the release zip (dry run)
./release.sh 1.0.0 --publish # tag v1.0.0 and publish it on GitHub (needs gh)
```

To release, set the version (**General → Identity → Version** on the target,
i.e. `MARKETING_VERSION`), commit and push, then run `release.sh` with that
version. Releases are ad-hoc signed and not notarized.

Enable the pre-commit hook with `git config core.hooksPath .githooks`.
See [docs/ui-testing.md](docs/ui-testing.md) for how the UI tests work and
[docs/](docs/) for design notes.

## License

MIT; see [LICENSE](LICENSE). Bundled and linked open-source software is
listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
