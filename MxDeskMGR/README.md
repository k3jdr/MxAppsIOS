# MxDeskMGR

A dual-pane file manager for macOS (SwiftUI and AppKit), in the spirit of **ForkLift** and **Total Commander**.

Open `MxDeskMGR.xcodeproj` in Xcode, then Run. There are no package dependencies. The app is **not sandboxed**
because a file manager needs to reach the whole disk. For protected folders (Desktop, Documents, external
drives) macOS asks for permission the first time; grant **Full Disk Access** in System Settings ▸ Privacy &
Security to skip those prompts.

## Window

| Part | What it does |
|------|--------------|
| **Sidebar** | **Favorites**: cloud storage first: **iCloud Drive** (when it is turned on) and each **OneDrive** account signed in with the OneDrive app (personal as "OneDrive", work or school as "OneDrive – Organisation"); also Go ▸ iCloud Drive / OneDrive. Then your folders. Drop folders here to add them, drag to reorder, right-click to remove. **Locations**: mounted volumes, with an eject button. **Servers**: Connect to Server… and recent servers. |
| **Two panes** | Each pane has **tabs** (a tab strip appears with 2+ tabs), Back / Forward / Up, a clickable **breadcrumb** path (right-click: Copy Path, Go to Folder…), a **quick filter**, the file list and a status line (items, selection size, free space). The active pane has an accent line on top. |
| **File list** | Columns Name, Ext, Size, Date Modified, Kind. Click a header to sort, drag to reorder or resize (remembered). Folders show `<DIR>` until you use **Calculate Folder Sizes**. The `..` row goes up. Hidden items are dimmed and symlinks are in italics. Folders update by themselves when their contents change. |
| **Transfer panel** | Running copies, moves, deletes and archive jobs, with progress and **Stop**. Jobs that hit problems stay listed, with the errors, until dismissed. |
| **Function key bar** | F2 Rename, F3 View, F4 Edit, F5 Copy, F6 Move, F7 New Folder, F8 Trash, ⌥F7 Find (View ▸ Function Key Bar). |

## Keyboard

In the file list: **Return** opens (enters a folder, opens a file), **Backspace** or **⌘↑** goes up,
**Tab** switches panes, **Space** opens Quick Look, **Escape** clears the filter, and typing a name jumps to it.
Select with click, ⇧-click and ⌘-click, or ⇧↑/⇧↓.

On a Mac keyboard, press **fn** with the F-keys unless "Use F1, F2, etc. keys as standard function keys" is on.

| Command | Keys |
|---------|------|
| New Tab / Close Tab | ⌘T / ⌃W |
| Next / Previous Tab | ⇧⌘] / ⇧⌘[ |
| Rename (several items: Multi-Rename) | F2 |
| View / Edit | F3 / F4 |
| Copy / Move to other pane | F5 / F6 |
| New Folder / New File | F7 / ⇧F4 |
| Move to Trash / Delete Immediately | ⌘⌫ / ⌥⌘⌫ |
| Quick Look | Space or ⌘Y |
| Duplicate | ⌘D |
| Properties | ⌘I |
| Copy / Paste files (Finder compatible) / Move Item Here | ⌘C / ⌘V / ⌥⌘V |
| Copy Path | ⌥⌘C |
| Select Group / Deselect Group / Invert Selection | ⌘= / ⌘- / ⇧⌘I |
| Show Hidden Files | ⇧⌘. |
| Sort by Name, Ext, Size, Date, Kind | ⌃⌘1 – ⌃⌘5 (again to reverse) |
| Calculate Folder Sizes | ⌥⌘S |
| Refresh | ⌘R |
| Back / Forward / Enclosing Folder | ⌘[ / ⌘] / ⌘↑ |
| Home, Desktop, Applications, Computer | ⇧⌘H, ⇧⌘D, ⇧⌘A, ⇧⌘C |
| Documents, Downloads | ⌥⌘O, ⌥⌘L |
| Go to Folder… | ⇧⌘G |
| Swap Panes | ⌘U |
| Same Folder in Other Pane | ⌥⌘= |
| Open Selected Folder in Other Pane | ⌥⌘→ |
| Add to Favorites | ⌃D |
| Find Files… | ⌘F |
| Multi-Rename… | ⌃M |
| Compare Folders (select differences) | ⌥⌘K |
| Synchronize Folders… | ⌥⌘Y |
| Compare Files by Content… | ⌥⌘D |
| Extract to Other Pane | ⌥F9 |
| Open Terminal Here | ⌥⌘T |
| Show in Finder | ⌥⌘R |
| Connect to Server… | ⌘K |

## File operations

**Copy / Move (F5 / F6)** asks for the target, which defaults to the other pane's folder. You can type another
folder, a relative path, or `~/…`. For a single item, a path that isn't a folder copies it under that name.
Choose what happens when an item already exists: **Ask**, **Replace**, **Replace if older**, **Skip** or
**Keep both**. Ask shows the sizes and dates of both and has *Apply to all*.

- A folder copied onto a folder of the same name is **merged**, not replaced.
- Files are copied with `copyfile(3)`: instant **APFS clones** where possible, otherwise a data copy with
  progress. Permissions, dates, extended attributes and ACLs are kept, and symlinks are copied as links.
- A move within one volume is a rename. Across volumes it is a copy, and each source is removed only after
  it has been copied completely.
- Copying an item into its own folder makes a Finder-style "name copy" duplicate.

**Drag and drop** works between panes, with Finder and with other apps. Within one volume a drag moves;
hold ⌥ to copy. Drop on a folder row to put the items into that folder.

**Trash (F8 / ⌘⌫)** moves items to the Trash. Settings can make it ask first. **Delete Immediately**
always asks and can't be undone.

**Compress** makes `name.zip` (or `Archive.zip` for several items) in the same folder. **Extract** unpacks zip,
tar, tgz, tbz, txz, 7z, rar, cpio, xar and iso archives into a new folder in the other pane.

**Properties (⌘I)** shows the kind, total size, dates and owner, and lets you change the permission bits
(optionally for everything inside a folder) and the modification date.

## Tools

| Tool | What it does |
|------|--------------|
| **Find Files** | Searches from a folder by name (wildcards such as `*.swift;*.md`, or a regular expression), by text the file contains, and by size and age limits, optionally into subfolders and hidden items. Double-click a result to show it in the active pane. Results can also be opened, shown in Finder or copied as paths. |
| **Multi-Rename** | Name and extension masks with `[N]` name, `[N2-5]` characters 2–5, `[E]` extension, `[C]` counter (start, step, digits), `[P]` parent folder, `[YMD]` and `[hms]` modification date and time. Search and replace (plain text or regex) and case changes. A live preview flags duplicates and names that are taken. Swapped names work, and **Undo** reverts the last batch. |
| **Compare Folders** | Selects, in both panes, the items missing from the other side or newer than their counterpart. |
| **Synchronize Folders** | Compares two folder trees by date and size, or by content. Each difference gets a direction (→, ←, or skip) that you can change per row or for a selection; then **Synchronize** copies. |
| **Compare Files** | A line diff of two text files: two marked in one pane, one marked in each pane, or a marked file and its same-named twin in the other pane. Binary files are compared byte for byte. **Open in FileMerge** hands both files to Xcode's FileMerge. |
| **Viewer (F3)** | Quick Look preview, text (with ⌘F find and line wrapping), or a hex dump. |
| **Connect to Server (⌘K)** | Mounts smb://, afp://, nfs://, ftp:// (read-only) and WebDAV (http/https) shares with NetFS and opens them in the active pane. The share also appears under Locations, and the address is kept in Recent. |

## Settings

Hidden files, folders first, the function key bar, confirmation before using the Trash, and which apps
**Edit (F4)** and **Open Terminal Here** use (TextEdit and Terminal by default; iTerm etc. work too).

The open tabs of both panes are saved and restored in the next window.

## Not included yet

- **SFTP / S3 / cloud connections** (ForkLift). Only protocols macOS can mount are supported. SFTP needs an
  SSH client library or macFUSE/sshfs.
- Thumbnail and column (Miller) views; the panes are list views.
- Packer plugins and the internal archive browser (Total Commander). Archives are extracted instead.
