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
- **Tables**: right-click a cell to insert or delete rows and columns, sort by a column, or turn the header row on/off.
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

## Notebooks on disk

A notebook is a folder named `Name.mxnotebook`, so it can live in iCloud Drive, OneDrive, Google Drive or Dropbox and
be opened on another Mac with File ▸ Open Notebook… (use **Reload Notebooks** after a sync).

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
