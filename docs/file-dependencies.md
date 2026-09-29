# File dependencies (HTML resources, markdown images) — design notes

**Status: on hold.** Nothing here is implemented yet. This records the
discussion so far and the direction we settled on, so we can pick it up later.

## Problem

HTML handling works but is a special case:

- `HTMLResources.copyResources` (`Cheatsheet/Store/HTMLResources.swift`)
  implicitly copies whatever a page's relative `href`/`src` point at into the
  sheet's **shared, flat** media folder. We never explicitly choose to load
  the CSS; it just happens.
- Nothing records which page owns which resource. Cleanup
  (`removeOrphanedResources` in `CheatsheetStore.swift`) re-parses every HTML
  page to guess.
- Two pages with the same `style.css` collide in the flat folder.
- The web view gets `allowingReadAccessTo:` the whole sheet folder, so a page
  can read other pages' files.
- Sync, export, and overlay editing don't know resources exist.
- Markdown can't show local images at all: it's loaded with
  `loadHTMLString(_:baseURL: nil)` (`MarkdownWebView.load`).

Goal: a unified approach for file types that depend on other files, without
adding complexity for simple types (images, PDFs, plain text).

## Where we landed (current direction)

**Scaled back**: HTML copies its files; markdown references images where
they live. We don't take ownership of arbitrary linked files.

### Why HTML and markdown differ

Both have standard reference syntax (HTML: `href`/`src`/`srcset`, CSS
`url()`/`@import`; markdown: `![](path)`). The difference is *where the
files live*:

- **Saved HTML** ("Save Page As → Complete") is a self-contained unit: the
  page plus a `<name>_files/` folder beside it. That folder is a strong
  convention (not a formal standard). Its resources belong to the page, so
  copying is natural. (JavaScript can load anything at runtime; out of scope.)
- **Markdown** points into a shared pool — an Obsidian attachments folder,
  `../images/`, screenshots anywhere. Copying means duplicating and
  maintaining someone's attachment library.

### Markdown images: render from the original's folder

No copies, and no per-file lookup table (the sandbox grants access per
folder, and relative paths can be resolved live against the original's
location, so a table adds nothing).

1. **Import**: if a markdown page references local images, ask once:
   *"notes.md shows images from ~/Notes. Allow access so they appear?"*
   Nothing is copied.
2. **Granted folders**: store a security-scoped folder bookmark in an
   app-wide list (not per page). Granting an Obsidian vault once covers every
   note from it, including later imports.
3. **Rendering**: a `WKURLSchemeHandler` (e.g. `cheatsheet-page://<pageID>/…`)
   resolves each image path against the **original file's folder** and
   serves it only if it's inside a granted folder. Handles `../../` and
   absolute paths. Markdown is loaded with a base URL on that scheme.
4. **Can't show an image** (no grant, moved, original deleted): placeholder
   with the alt text, plus one "Allow access…" action on the page. No errors,
   no modals.
5. **Settings**: a short "Folders with access" list with Remove buttons (the
   usual pattern for sandboxed markdown apps with vaults).

How this fits what exists:

- **Sync toggle**: independent. Images are read-only views, rendered with
  sync on or off.
- **Original location**: we already store a bookmark to every original
  (`FileLink`, recorded even with sync off), and it follows moves. If the
  original is deleted, fall back to its last-known folder.
- **Export / another Mac**: the text travels, images don't; they show the
  placeholder until that Mac grants its own folder. State this in the export
  sheet. Possible later: optional "include images" snapshot on export.
- **Overlay editing**: a newly added image just works if it's in a granted
  folder; otherwise placeholder + "Allow access…".

### HTML: keep copying, two fixes

- **Per-page subfolder** for each HTML page's resources: no `style.css`
  collisions, and deleting a page removes only its own files (replaces the
  re-parse-and-guess cleanup).
- **Consent**: the existing folder-access prompt (`HTMLResourceAccess`) only
  appears when resources are found next to the page. Extend its message to
  list what will be copied — the "show what was found, then ask" behavior
  without a checklist UI.

### Suggested build order

1. URL scheme handler + markdown images read from granted folders.
2. Import prompt + granted-folders list in settings.
3. HTML per-page resource subfolders (with migration of existing sheets).

## Alternatives considered (and why not, for now)

### A. Full dependency system with copies (first proposal)

Every page becomes a folder `sheets/<sheetID>/<pageID>/` with its main file
and dependencies; the model gets `resources: [String]`; a per-type
`DependencyScanner` (HTML, markdown, …; others return `[]`); a scheme handler
serves only listed files; settings show "Includes N files" / "N missing —
Locate…"; sync and edits re-scan; export ships the page folder.

Refinements discussed:

- **Ask before importing**: scan the page text (works before any sandbox
  grant), import silently if nothing is found, otherwise show a checklist of
  found references, then request one folder grant covering the chosen items.
  Existence/size can only be checked after the grant. New references from
  sync or edits would show a non-modal "2 new files referenced — Review…"
  banner.
- **No mirrored directory tree, no link rewriting**: store assets flat
  (`assets/1-diagram.png`) with a manifest mapping *reference as written →
  stored file*. The scheme handler places the page at an artificial depth
  (as deep as its deepest `../` climb) so `../../x` resolves to distinct
  virtual paths. Root-absolute paths resolve under the scheme too.
  `file:///` and `~/` get redirected at markdown render time; unsupported in
  HTML. Remote `https:` stays network.

Rejected for now: too much ownership of arbitrary files (copying and
maintaining attachment libraries) for a cheatsheet app.

### B. Lookup table from each markdown reference to the real file

A per-reference table of security-scoped bookmarks. Works, but the sandbox
needs a user grant anyway, and grants are per folder; once a folder is
granted, resolving relative paths live is simpler than managing per-file
bookmarks. Folded into the chosen direction as "granted folders".

## Other file types (reference, not planned)

| Type | Dependencies | Notes |
| --- | --- | --- |
| Obsidian markdown (`![[image.png]]`) | by name, vault-wide | Common for cheatsheets. Needs name lookup inside a granted folder; ask if ambiguous. |
| SVG | sometimes (`href` to images/fonts) | Same scanner as HTML. Can contain scripts: render in web view, never inline. |
| Safari `.webarchive` | none (self-contained) | Best way to import a web page; WebKit loads it natively. Could suggest it when someone imports a `_files` page. |
| TextBundle (`.textbundle`/`.textpack`) | inside the package | Markdown + assets (Bear, Ulysses, iA Writer). Import whole, no prompt. Possible "Export page as TextBundle". |
| RTF / RTFD | RTFD is a package with images | `NSAttributedString`; copy the whole package. |
| PDF | none | Multi-page; maybe one cheatsheet page per PDF page. |
| Source code / config | none | Text + syntax highlighting. |
| CSV / TSV | none | Render as a table (shortcut tables). |
| Office / iWork | none | Quick Look `QLPreviewView`, read-only. |
| Jupyter `.ipynb` | none (images embedded) | Niche. |

Markdown math (KaTeX) and Mermaid are renderer features, not dependencies.

## Prior art

- **Local resources in a web view**: VS Code webviews use an allow list
  (`localResourceRoots`) served through a custom scheme; Obsidian serves
  local files via its `app://` scheme. On macOS the native equivalent is
  `WKURLSchemeHandler`.
- **Packaging a document with its resources**: EPUB (an explicit manifest of
  every resource), Safari `.webarchive`, TextBundle, RTFD, MHTML (Chrome;
  WebKit on macOS can't open it).
- **Note importers** (Notion, Bear, Obsidian) usually copy attachments and
  rewrite links. We avoid rewriting because pages sync with originals the
  user edits elsewhere.
- **Sandboxed sibling access**: Apple's `NSIsRelatedItemType` only covers
  files with the same base name (movie + subtitles), so it can't reach
  `../shared/`; a one-time folder grant via `NSOpenPanel` is the practical
  route.
- **Displaying arbitrary types**: Quick Look.

## Relevant code today

- `Cheatsheet/Store/HTMLResources.swift`: reference scanning and copying for HTML.
- `Cheatsheet/Settings/HTMLResourceAccess.swift`: folder-access prompt at import.
- `Cheatsheet/Store/CheatsheetStore.swift`: `copyFiles`, `removeOrphanedResources`.
- `Cheatsheet/Rendering/MarkdownWebView.swift`: `load(_:format:into:)`
  (markdown as a string; HTML via `loadFileURL`).
- `Cheatsheet/Store/OriginalFiles.swift`, `Cheatsheet/Models/FileLink.swift`:
  original-file bookmarks and sync.
- `Cheatsheet/Store/LibraryArchive.swift`: export/import (includes HTML resources).
