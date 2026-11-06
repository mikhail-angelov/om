# om

A local Markdown vault for macOS: a folder of files, a headless engine that
understands the links between them, a command-line tool, and an editor with
live preview.

Nothing is synced anywhere. A vault is a directory; the notes in it are plain
files you can edit with anything else. Every file in the folder is listed, not
only the Markdown: a `.txt` or a `.json` opens and edits like a note, a file
whose bytes are not text is shown but not opened, and dotfiles stay out of the
way. `[[Links]]` address a note by its bare name or by its filename, so both
`[[Notes]]` and `[[notes.txt]]` find it.

## Requirements

macOS 14 or later and a Swift 6 toolchain. The vault engine and the CLI have no
dependencies beyond Foundation; the editor uses
[swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine).

## Install

```sh
brew install --cask mikhail-angelov/tap/om
```

The cask lives in the [homebrew-tap](https://github.com/mikhail-angelov/homebrew-tap)
repository and is updated on every tagged release; if `brew` does not know the
tap yet, `brew tap mikhail-angelov/tap` first.

## Build and install

```sh
make            # list the targets
make test       # run the suite
make install    # build and put Om.app in ~/Applications
make run        # install and launch
```

`make install` writes into `~/Applications` by default. To install elsewhere:

```sh
make install PREFIX=/Applications
```

`make release` runs the tests, builds the bundle and packages
`build/Om-<version>.zip`. The version comes from `git describe`, so tag a
commit before cutting one:

```sh
git tag -a v0.2.0 -m "Vault shell"
make release
```

`make uninstall` removes the installed application; `make clean` removes build
products.

## The command-line tool

`make cli` prints the path to the built binary. It reads a vault and writes
JSON to stdout:

```sh
om index     <vault>                 # every note: path, name, title
om links     <vault>                 # resolved links and broken ones
om backlinks <vault> <note>          # what points at a note
om rename    <vault> <old> <new>     # rename, updating every inbound link
om search    <vault> <text>          # case-insensitive text search
om log       [--tail N]              # recent entries from the event journal
```

`om rename` edits the vault in place. Copy a fixture before experimenting with
it. A rename keeps the file's kind: `notes.txt` becomes `<new>.txt`.

Encrypted notes are opaque to the command-line tool: `om index` lists them,
and nothing reads inside them.

## The editor

`Om.app` opens a folder as a vault and remembers it, along with the tabs that
were open, between launches.

| | |
|---|---|
| `⌘F` | find inside the open note, with match count and `⌘G` to step |
| `⌘⇧F` | search every note in the vault |
| `⌘S` | save now — edits also autosave shortly after you stop typing |
| `⌥↑` / `⌥↓` | move the current line up or down |
| `⌥⇧↑` / `⌥⇧↓` | duplicate the current line above or below |
| `Esc` | close the in-note find bar |

The sidebar keeps the width it was dragged to, lists folders before files in
every sort order, and carries its own sort control beside the search field.

Notes and folders are created, renamed and deleted from the sidebar's context
menu. Renaming a note rewrites every link that pointed at it, exactly as
`om rename` does. Following a `[[link]]` moves the window's history, which the
back and forward arrows walk.

## Encrypted notes

A vault can carry one password, set from the toolbar's lock. **Encrypt…** in a
note's context menu seals it: `Secret.md` becomes `Secret.omenc`, and the
original file is removed. A sealed note shows with a lock in the tree, opens
only while the vault is unlocked, and re-seals on every save. **Decrypt…**
turns it back into the file it was, extension and all.

The password is never stored. What sits beside the notes, in
`.om/security.json`, is a random salt and a verifier: the key is derived with
PBKDF2-HMAC-SHA256 (600,000 iterations) and notes are sealed with AES-GCM, so a
tampered file fails to open rather than decrypting to something else. Lose the
password and the notes are gone — there is no recovery, by design.

Locking the vault drops the key and closes every tab holding a decrypted note.
Sealed notes never appear in vault search, unlocked or not: the search reads
files from disk, and on disk there is nothing to read.

## Diagnostics

Every user action is recorded as one JSON object per line in
`~/Library/Logs/om/om.log`, and the file is rotated at 5 MB. `OM_LOG_LEVEL`
sets the threshold (`debug`, `info`, `warn`, `error`; default `info`).

An uncaught exception or a fatal signal is written as an `app.crash` entry,
with its reason and a stack, before the process dies — the first version of
this application vanished during AppKit layout and left nothing at all behind.
An exception thrown by the rendering library is recorded as `render.failed` and
does not take the editor with it.

```sh
tail -f ~/Library/Logs/om/om.log
om log --tail 20
```

## Layout

```text
Sources/OmVault/       the vault engine: index, links, backlinks, rename, search
Sources/OmCrypto/      the vault password and the seal around an encrypted note
Sources/OmShell/       application logic, headless — no SwiftUI, no AppKit
Sources/OmEditor/      the SwiftUI layer, which only displays and sends intent
Sources/om/            the command-line tool
Sources/Om*Support/    small Objective-C bridges for the crash and render handlers
scripts/icon.swift     the application icon, drawn in code and built at bundle time
Fixtures/vault/        a vault carrying every link shape the renamer must survive
```

The split between `OmShell` and `OmEditor` is deliberate: behaviour that lives
inside a view cannot be tested without driving a user interface, and an earlier
version of this application had three requirements that no test could reach for
exactly that reason.

## Specifications

`BRIEF.md` and `BRIEF-2.md` are what the application was built against, phase by
phase, with numbered acceptance criteria. They are kept as written, including
the places where they turned out to be wrong: `docs/AI_LEARNED.md` records what
each phase taught.
