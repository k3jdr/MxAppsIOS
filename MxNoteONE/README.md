# MxNoteONE

A digital notebook for macOS (SwiftUI and AppKit), in the spirit of **Microsoft OneNote**.

Open `MxNoteONE.xcodeproj` in Xcode, then Run. There are no package dependencies. The first launch creates
**My Notebook** with a **Quick Notes** section and a Welcome page in `~/Documents/MxNoteONE Notebooks`
(change the folder in Settings).

## Window

| Part | What it does |
|------|--------------|
| **Sidebar** | Open notebooks, each with its **sections** (coloured tabs) and **section groups** (folders, can nest). Right-click a notebook, section or group to rename, recolour, move up/down or into a group, password protect, export or delete it. **+** adds a section, section group or notebook; the tag and trash buttons open the Tag Summary and Recycle Bin. The search field searches every open notebook. |
| **Page list** | Pages of the selected section with date and first line. Subpages are indented (two levels) and can be collapsed; drag to reorder (subpages move with their page). Right-click for New Page / Subpage, Make Subpage, Promote, Move or Copy…, Duplicate, Copy Link to Page, Export as PDF / Markdown, Print, Delete. While the search field has text, this column shows the search results instead. |
| **Ribbon** | **Home**: font, size, bold, italic, underline, strikethrough, superscript/subscript, highlight and font colours, clear formatting, bullets, numbering, indent, alignment, line spacing, styles (Heading 1–4, Title, Quote, Code), tags. **Insert**: table, picture, file attachment, screen clipping, audio recording, link, date / time stamps, page templates. **Draw**: type, pen, highlighter, eraser, line, arrow, rectangle, ellipse, pen colours and thickness. **View**: page colour, rule lines and grids, zoom, full page view, Tag Summary, Recycle Bin. |
| **Page** | A title and creation date, then a free-form canvas: click anywhere to start a text container there. Drag a container by its top bar, resize it from its right edge, right-click the bar for Cut / Copy / Delete / Bring to Front / Send to Back. Click a container's bar (or press Escape while typing) to select it; then Delete removes it and the arrow keys nudge it. Drop pictures and files onto the page. Pinch or use View ▸ Zoom. The page is always drawn as light paper. |

## Pages

- **Text containers** hold rich text (fonts, colours, highlights, lists, inline pictures). Typing grows the container.
- **Bullets and numbering**: Return continues the list, Return on an empty item ends it, Tab / Shift-Tab indent items.
- **Tags**: ☐ To Do, ⭐ Important, ❓ Question, ❗ Critical, 💡 Idea, 📌 Remember for Later, 📖 Definition, 📞 Phone Number,
  💬 Discuss with Team (⌘1 – ⌘9, ⌘0 removes). Click ☐ to check it off; Return after a To Do starts another.
- **Tables, OneNote style**: type some text and press **Tab** — the paragraph becomes a table with your text in the
  first cell. While the table has one row, **Tab** in a filled last cell adds a column; **Return** in the last row adds
  a row; **Tab** in the last cell of the last row adds a row; **⌘Return** inserts a row below; **⇧Tab** goes back;
  **⌥Return** starts a new line inside a cell; **⌥Tab** types a real tab in text. Pressed Tab or Return once too
  often? **Backspace** in the empty new cell removes the empty column (or row) again. Text after the paragraph moves
  below the table, and a growing table (or text container) pushes the container right under it down.
- **Selecting cells**: click a cell to type in it; **drag** across cells, **⇧-click**, or **⇧-arrow keys** to select a
  block, **⌘-click** to add single cells; selected cells are highlighted. With cells selected (press Escape while
  typing to get there): typing replaces the cell, Delete clears the cells, Return edits, ⌘C / ⌘X / ⌘V copy, cut and
  paste cells as tab-separated text, ⌘A selects the whole table; Escape again selects the table container.
- **Cell shading and table commands**: right-click a cell — also while typing in it — for **Shade Selected Cells**,
  **Header Row**, **Row**, **Column** and **Table Shading** (a colour palette, or No Color), inserting and deleting rows
  and columns (for all selected rows / columns), clearing cells, sorting by a column and the header row switch. Text
  turns white on dark shades. Shading moves with its row when sorting, new columns take the shading of the column
  beside them, and it prints, exports to PDF and syncs with OneNote.
- **Pictures**: double-click to open in a viewer; right-click to copy, save, or reset to original size.
- **Attachments** keep a copy of the file inside the notebook; double-click to open. **Recordings** play in place.
- **Ink**: pen and highlighter strokes, lines, arrows, rectangles and ellipses (hold Shift for 45° lines, squares, circles).
  The eraser removes whole strokes. Press Escape to go back to typing.
- **Links**: type `[[Page Name]]` to link to a page in the notebook (it is created if it doesn't exist), or use ⌘K for
  web links and links to any page. Right-click a page ▸ Copy Link to Page and paste it anywhere in your notes.
- **Templates**: To Do List, Meeting Notes, Project Overview, Lecture Notes (Cornell), Daily Journal, Weekly Planner, Decision Log.
- Everything saves automatically. Undo / Redo covers typing, formatting, moving, resizing, inserting, deleting and ink.

## Keyboard

| Command | Keys |
|---------|------|
| New Page / New Subpage / New Quick Note | ⌘N / ⌥⌘N / ⌃⌘N |
| New Section | ⌘T |
| Open Notebook… | ⌘O |
| Search All Notebooks / Find on Page | ⌘E / ⌘F (⌘G, ⇧⌘G for next / previous) |
| Bold / Italic / Underline / Strikethrough | ⌘B / ⌘I / ⌘U / ⌃⌘- |
| Superscript / Subscript / Highlight | ⌃⌘= / ⌃⇧⌘= / ⌃⌘H |
| Bigger / Smaller | ⇧⌘> / ⇧⌘< |
| Heading 1 – 4 / Normal | ⌥⌘1 – ⌥⌘4 / ⌥⌘0 |
| Bullets / Numbering | ⌘. / ⌘/ |
| Clear Formatting | ⇧⌘N |
| Tags / Remove Tag / Tag Summary | ⌘1 – ⌘9 / ⌘0 / ⇧⌘T |
| Link… | ⌘K |
| Date / Time / Date & Time | ⌥⇧D / ⌥⇧T / ⌥⇧F |
| Insert Table / Picture / Screen Clipping / Record Audio | ⌃⌘T / ⌃⌘P / ⌃⇧⌘S / ⌃⌘R |
| Back / Forward | ⌘[ / ⌘] |
| Previous / Next Page | ⌥⌘↑ / ⌥⌘↓ |
| Previous / Next Section | ⌥⌘← / ⌥⌘→ |
| Make Subpage / Promote Subpage | ⌥⌘] / ⌥⌘[ |
| Move or Copy Page… | ⇧⌘M |
| Zoom In / Out / Actual Size | ⌘= / ⌘- / ⌃⌘0 |
| Full Page View / Show Ribbon | ⌥⌘F / ⌥⌘R |
| Lock All Protected Sections | ⌃⌘L |
| Export Page as PDF… / Print Page… | ⇧⌘E / ⌘P |
| Reload Notebooks | ⇧⌘R |
| Save Notebook As… | ⇧⌘S |
| Sync All OneDrive Notebooks | ⌃⌘S |

## OneDrive and Microsoft OneNote

Notebooks sync with **OneNote notebooks on OneDrive** through Microsoft's OneNote API, so the same notebook opens in
OneNote for Mac, Windows, iPad and the web (OneNote for Mac only opens notebooks kept on OneDrive or SharePoint).

- **File ▸ OneDrive ▸ Save “Notebook” to OneDrive** creates the OneNote notebook and uploads its sections, section
  groups and pages. After that, **Sync** (or ⌃⌘S for all OneDrive notebooks, or automatic sync in Settings) works both ways.
- **File ▸ OneDrive ▸ Open Notebook from OneDrive…** lists your OneNote notebooks and downloads one into a local notebook.
- Right-click a synced notebook (☁︎ in the sidebar) for **Sync**, **Open in OneNote**, **Open in OneNote for the Web**
  and **Stop Syncing**.

Page by page: changed only here → uploaded; changed only in OneNote → downloaded; changed in both → the OneNote
version comes down as a separate “(OneDrive copy)” page and the local version goes up; deleted on one side and
unchanged on the other → deleted on both (locally into the Recycle Bin).

What carries over: page titles, positions of containers, text formatting (fonts, sizes, colours, highlight, bold,
italic, underline, strikethrough, superscript/subscript, alignment), bullets and numbering, links, tags (To Do with
its check mark, Important, Question, Critical, Idea, Remember for Later, Definition, Phone Number, Discuss), tables,
pictures and attached files. Ink is uploaded as a picture. Not possible through the OneNote API: renaming or deleting
sections, setting subpage levels in OneNote, page colours and rule lines. **Password-protected sections stay on this
Mac** and are never uploaded.

**One-time setup** (Settings ▸ OneDrive has the same steps):

1. In the [Azure portal](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade), App
   registrations ▸ New registration; supported accounts: any organizational directory and personal Microsoft accounts.
2. Authentication ▸ Add a platform ▸ iOS / macOS, bundle ID `com.k3jdr.MxNoteONE` (redirect URI
   `msauth.com.k3jdr.MxNoteONE://auth`).
3. API permissions ▸ Microsoft Graph ▸ Delegated: `Notes.ReadWrite`, `User.Read`.
4. Paste the Application (client) ID into Settings ▸ OneDrive and Sign In. The sign-in is remembered in the Keychain.

## Notebooks on disk

A notebook is a folder named `Name.mxnotebook`, so it can live in iCloud Drive, OneDrive, Google Drive or Dropbox and
be opened on another Mac with **File ▸ Open Notebook…** (⌘O; use **Reload Notebooks** after a sync).
**File ▸ Save Notebook As…** (⇧⌘S) copies a notebook to another place — on this Mac or in your OneDrive folder — and
keeps working with the copy; **New Notebook…** offers your OneDrive folders as locations.

```
Name.mxnotebook/
  notebook.json          section tree, colours, recycle bin
  sections/<id>.json     a section's page list and search index (titles, text, tags)
  pages/<id>.json        a page: title, style, containers (rich text as RTFD, tables), ink
  assets/<id>.<ext>      pictures, attachments and recordings
```

**Password-protected sections** encrypt their section file, pages and assets with AES-GCM using a key derived from the
password (PBKDF2-SHA256, 200,000 rounds). Locked sections are hidden from search and the Tag Summary. Sections lock
again after a time away from the app (Settings). A forgotten password cannot be recovered.

**Recycle Bin**: deleted pages and sections are kept for 60 days per notebook; restore or delete them from
View ▸ Recycle Bin.

## Permissions

The app is not sandboxed, so notebooks can be anywhere. macOS asks once for the **microphone** (audio recordings)
and for **screen recording** (screen clippings, which use the system `screencapture` tool).
