# MxFileMGR

A dual-pane file manager for macOS (SwiftUI and AppKit), in the spirit of **ForkLift** and **Total Commander**.

Open `MxFileMGR.xcodeproj` in Xcode, then Run. There are no package dependencies. The app is **not sandboxed**
because a file manager needs to reach the whole disk. For protected folders (Desktop, Documents, external
drives) macOS asks for permission the first time; grant **Full Disk Access** in System Settings ▸ Privacy &
Security to skip those prompts.

The app was called **MxDeskMGR** until 2026-10-16. On its first launch under the new name it copies the old
preferences (favorites, open tabs, recent servers, S3 profile, column layouts). macOS treats it as a new app for
privacy permissions, so it asks again for Photos and protected folders.

## Window

| Part | What it does |
|------|--------------|
| **Sidebar** | **Favorites**: cloud storage first: **iCloud Drive** (when it is turned on) and each **OneDrive** account signed in with the OneDrive app (personal as "OneDrive", work or school as "OneDrive – Organisation"), the **SharePoint** document libraries the OneDrive app syncs (one "SharePoint – Organisation" folder per organisation, holding a "Site - Library" folder for each library; with none synced, the SharePoint entry explains how and opens OneDrive), **Teams Chat Files** (the "Microsoft Teams Chat Files" folder Teams keeps in each OneDrive account; channel files come with the SharePoint libraries; with neither on the Mac, a Microsoft Teams entry explains where Teams files live and opens Teams) and each **Google Drive** account from Google Drive for desktop ("Google Drive", or "Google Drive – email" with several accounts) and each **Dropbox** account ("Dropbox" for personal, "Dropbox – Team" for business) and **Box** (Box Drive); also Go ▸ iCloud Drive / OneDrive / SharePoint / Microsoft Teams / Google Drive / Dropbox / Box. **WebDAV accounts** (Nextcloud, ownCloud, a NAS, …) are saved with **Add WebDAV Account…** (name, http/https address, user; the password goes in your login Keychain if you choose, otherwise macOS asks when connecting): click one to mount the share — or find it already mounted — and open it in the active pane; right-click to edit, disconnect or remove it; also Go ▸ WebDAV. **SFTP accounts** are saved with **Add SFTP Account…** (a host or an alias picked from `~/.ssh/config`, optional user, port and starting folder; sign in with your SSH key or agent exactly as `ssh` does, or a password kept in your login Keychain; **Test Connection** tries it). macOS can't mount SFTP, so an account opens its own window, driven by the system's `sftp`: browse, **Download** to the active pane, **Upload** what's marked there or drop files, **New Folder**, **Rename**, **Delete** (folders with everything in them, after asking), **Copy sftp:// Link**; also Go ▸ SFTP. New host keys are accepted the first time; a changed host key is refused. **iCloud Photos**, **Amazon S3**, **Azure Blob Storage** and **Google Cloud Storage** open their browser windows (see Tools). Then your folders. Drop folders here to add them, drag to reorder, right-click to remove. **Locations**: mounted volumes, with an eject button. **Servers**: Connect to Server… and recent servers. |
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
| Show Clipboard | ⇧⌘V |
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

**ffmpeg Meta-data…** (right-click a single `.mp4`, `.m4v`, `.mov`, `.webm`, `.mkv`, `.avi`, `.mp3` or `.m4a` file) edits its **Title** and **Description** tags with
[ffmpeg](https://ffmpeg.org) (`brew install ffmpeg`), filled in with the current values read by `ffprobe`. **Apply** runs
`ffmpeg -i in -map 0 -map_metadata 0 -c copy -ignore_unknown -metadata title=… -metadata description=… out`: every stream
is copied without re-encoding, the other tags are kept, and an empty field removes its tag. The original is replaced once
the new copy is written (or choose **Save as a new file**); progress shows in the transfer panel, and **Command** shows the
equivalent command. For `.mov` it adds `-movflags use_metadata_tags` (QuickTime's standard tags have no description) and blanks the
duplicated `major_brand` / `minor_version` / `compatible_brands` tags that option would otherwise accumulate. AVI's tags have no
description, so for `.avi` the Description is stored in (and read from) the comment tag (ICMT). For `.mp3` the Description is a
custom ID3 frame (`TXXX:description`, not shown by music players), and the command adds `-id3v2_version 3 -write_id3v1 1` so
the tags stay ID3v2.3 and ID3v1 tags are kept (plain ffmpeg would write 2.4 and drop ID3v1).

**Edit ▸ Show Clipboard** (⇧⌘V) opens a **Clipboard** window, as in Finder: *Clipboard contents: …* and the content itself —
copied files (name, folder, size; a **Quick Look preview** of the selected one, which **Preview** hides or shows;
double-click opens a file in the Viewer; **Paste into** the active pane's folder, **Move Here**, **Show in Finder**), a picture
(format and pixel size), styled text, plain text (character and line counts), a link or a colour — plus the data types
underneath and **Clear Clipboard**. It follows the clipboard while open (macOS has no change notification, so it checks
twice a second).

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
| **iCloud Photos** | The Photos library isn't a plain folder, so this window uses Apple's Photos framework (macOS asks for access once). Browse All Photos, smart albums (Favorites, Recents, Videos, Live Photos, …) and your albums; filter photos, videos or **Long Videos** (1 min+, longest first); newest or oldest first; resize thumbnails. Click to select. **Export** writes the **originals** (plus a Live Photo's video and both halves of RAW+JPEG) into the active pane's folder, downloading from iCloud as needed, dated with the photo's date. **Clean up**: **Delete…** (or the Delete key) moves items to Recently Deleted in Photos after Photos' own confirmation (recoverable for 30 days); **Duplicates** shows likely duplicates (same type, size, capture second and duration) in numbered groups, and **Select Extras** selects all but one per group (a favorite is kept); **Organize** ▸ Favorite / Unfavorite, Hide, Add to Album, New Album with Selection, Remove from the album. **Albums**: New Album, and right-click an album to **Rename** or **Delete** it (its photos stay in the library). **Rename photos**: Photos can't rename a photo, so **Export & Rename…** exports the originals and opens Multi-Rename on the exported files. Right-click a photo to act on just that one. Changes made in the Photos app show up here automatically. |
| **Amazon S3** | S3 has no local folder, so this window works through the installed **AWS CLI** with your `~/.aws` profiles, including IAM Identity Center (SSO); the app never reads or stores access keys. Pick a profile and bucket, browse folders (breadcrumb, Up, filter; the first 10,000 items per folder are listed). **Download** to the active pane's folder (double-click a file, or folders recursively); **Upload** the items marked in the active pane, or drop files from a pane or Finder onto the list; **New Folder**, **Rename** (`aws s3 mv`), **Delete** (asks first; S3 has no trash), **Copy S3 URI**, **Copy Presigned Link** (7 days). Transfers run in the transfer panel with progress. When an SSO session has expired, **Sign In** runs `aws sso login`, which opens the browser to approve. Shown in Favorites when the AWS CLI and a profile are present (install with `brew install awscli`). |
| **Azure Blob Storage** | Works through the **Azure CLI** (`brew install azure-cli`) after you sign in with **Sign In** (`az login`, in the browser); the app never stores account keys. Pick a subscription, storage account and container, then browse folders (breadcrumb, Up, filter; first 10,000 items per folder). **Download** to the active pane's folder (folders with everything in them), **Upload** the pane's marked items or drop files onto the list, **Rename** files (copy, then delete the original), **Delete** (asks first), **Copy URL**, **Copy SAS Link** (read-only, 7 days). **New Folder** opens an empty folder that is kept once you upload into it (Blob Storage has no empty folders). Data access uses your Microsoft Entra sign-in; if the account refuses it (no *Storage Blob Data* role), the window retries with the account key. |
| **Google Cloud Storage** | Works through the **Google Cloud CLI** (`brew install --cask google-cloud-sdk`) after you sign in with **Sign In** (`gcloud auth login`, in the browser); the app never stores keys. Pick a project and bucket, then browse folders (breadcrumb, Up, filter). **Download** to the active pane's folder (folders with everything in them), **Upload** the pane's marked items or drop files onto the list, **Rename** (`gcloud storage mv`, folders too), **Delete** (asks first), **Copy gs:// URI**, **Copy Browser Link** (opens for anyone signed in with access). **New Folder** opens an empty folder that is kept once you upload into it. |
| **Viewer (F3)** | Quick Look preview, text (with ⌘F find and line wrapping), or a hex dump. |
| **Connect to Server (⌘K)** | Mounts smb://, afp://, nfs://, ftp:// (read-only) and WebDAV (http/https) shares with NetFS and opens them in the active pane. The share also appears under Locations, and the address is kept in Recent. |

## Quick Help

**View ▸ Quick Help** (⌥⌘/) shows a panel at the bottom of the sidebar, as in MxNoteONE, MxDataHUB and MxJobsMGR,
telling what's under the pointer in a sentence or two, with its shortcut: toolbar and pane buttons, the path bar,
filter, tabs, function keys, sidebar entries, the transfer panel — and in the file lists the item under the pointer
(kind, size, date and what Return, Space, F3 and F4 do) or the column header (and how it's sorted). Over nothing it
can describe, it tells about the marked items or the folder, and then about the window or sheet in front; the tool
windows (Find Files, Multi-Rename, Synchronize, Viewer, Compare Files, iCloud Photos and the cloud storage windows)
describe themselves too. **View ▸ Float Quick Help** (or the panel's float button) puts it in a small window of its
own; closing that window docks it again. Both choices are remembered. The panel is the shared one in
`../Shared/QuickHelp`; what it says in MxFileMGR is in `FileQuickHelp.swift`.

## Settings

Hidden files, folders first, the function key bar, confirmation before using the Trash, and which apps
**Edit (F4)** and **Open Terminal Here** use (TextEdit and Terminal by default; iTerm etc. work too).

The open tabs of both panes are saved and restored in the next window.

## Not included yet

- **SFTP / S3 / cloud connections** (ForkLift). Only protocols macOS can mount are supported. SFTP needs an
  SSH client library or macFUSE/sshfs.
- Thumbnail and column (Miller) views; the panes are list views.
- Packer plugins and the internal archive browser (Total Commander). Archives are extracted instead.
