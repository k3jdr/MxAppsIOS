# spending-web — Spending Analysis on the home network

MxAcctMGR's **Reporting ▸ Spending Analysis** as a web page for the rest of the family. It shows the same
numbers and tabs, but nothing on it can change the data. Each section, purchase and rule has a way to send John a note.
The notes land in the security master (`srm.spending_feedback`, V039). MxAcctMGR's **Feedback** tab shows them, with
a status and a reply that the page shows back under **My Notes**.

It runs on **K3JDR-DSKTOP-11** (192.168.0.223), next to the security master, so the page is up whenever the PC is,
whether or not the Mac is on.

## The link

MxAcctMGR's **Send Family Link** (Spending Analysis) sends it by Mail or Messages.

`http://192.168.0.223:8780/s/<key>/`, or `http://k3jdr-dsktop-11.local:8780/s/<key>/`. The key is in
`spending_web.local.json` on the PC. Anyone who has the link and is on the home network can open the page:

- **Home network only.** Windows Firewall opens port 8780 to the local subnet on the Private profile only. The server
  also answers only addresses in `allow` (192.168.0.0/24, the PC itself, and IPv6 link-local, which is how a Mac reaches
  `*.local`).
- **Secret path.** Without the key, every path is a bare 404, so the page gives no hint that it exists. The key never
  goes to the server's log, and pages are sent with `Referrer-Policy: no-referrer`.
- **Limited login.** The server signs in as `spending_web` (V039, V041). That login can read what the page shows, add
  notes, write entries' tags, and change a lifecycle trigger's category and kind, and nothing else. It sees target accounts by name only: their logons and addresses are not readable. Its
  password exists only in the PC's config file, readable by the PC account, SYSTEM and Administrators.
- **The link doesn't change, key included.** Publishing (`publish-to-pc.sh`), releases, restarts, reboots and
  re-running the installer all keep it. Nothing expires or rotates it. The publish script never copies the PC's
  `spending_web.local.json`, and checks after every run that the file is unchanged.
- **Only John changes it**, when he chooses and after telling the family. To do that, put a new key in
  `spending_web.local.json` on the PC (`python spending_web.py --new-key` prints one), restart the task, and send
  the new link. The old link then stops working.

## What the page has

The tabs are Overview (the attribution), Deep Dive, Year-End Tax (with ⬇︎ Download CSV, the same file MxAcctMGR's Export CSV… saves), Entries, Family & Lifecycle, Sources and My Notes. Rules are MxAcctMGR's only. They show
the same calculations as MxAcctMGR: `static/app.js` ports SpendingEngine's attribution (`SpendingModel.swift`). The
Forward Curve stays in MxAcctMGR only; the Deep Dive lists a category's lifecycle triggers without it. They read the
same queries, through `Services/accounts/spending.py`. Viewing choices are allowed and are kept in the browser: the
year, *Year to date*, *Only registers covering both years*, the Deep Dive category, the entry filters, and the
entries tables' Payee width (drag the grip at its header's right edge, with a mouse or a finger; double-click it for the
standard width; longer names end in "…" and show in full on hover). It can change two things (V041), each applied at once, with
nothing to fill in: signed with the name she gave for notes, else "Family page":

- **An entry's Category and Driver**, in the entries tables on Entries and in the Deep Dive. A change gives the entry a
  tag of its own, as MxAcctMGR's Tag Entry does. *By the rules* clears her choice, so the rules decide again.
- **A lifecycle trigger's Category and Kind**, on Family & Lifecycle.

Each change is also a note: MxAcctMGR's Feedback tab lists it as "A change on the family page", with what it was
before, and **Undo** puts that back. Under My Notes she sees her changes, Made or Undone. Nothing else can be changed
from the page: not rules, sources, the family, triggers' ages or costs, or tax items.

**Feedback.** The 💬 Feedback button at the top, the 💬 Note on every section, ⚑ on every purchase, and *Suggest a
change* on every rule and lifecycle trigger all open one short form:

- her name (remembered);
- what the note is about: how the page looks, a number, a category or rule, one purchase, an idea, or a question;
- for a rule or a purchase, the category and driver she would choose;
- the note itself.

Each note also records which tab and section it came from and the page's settings. For a purchase it records its date,
payee, amount, category and driver, so John can find it without asking. **My Notes** lists her notes with their status
(New, Seen, Planned, Done, Not planned) and John's reply; the tab shows how many replies are new.

## Files

| File | Contents |
| --- | --- |
| `spending_web.py` | The server: Python standard library and psycopg2. IPv4 and IPv6 on one socket; address and key checks; static files and the API (`/api/setup`, `/api/analysis`, `/api/sources`, `/api/tax`, `GET` and `POST /api/feedback`). It writes its log to a file when it runs without a console. |
| `static/index.html`, `app.css`, `app.js` | The page: no outside libraries; charts drawn as SVG at each box's width; light and dark; usable at phone width |
| `spending_web.example.json` | The config's shape: copy it to `spending_web.local.json` (not in git) and fill in the key and password |
| `publish-to-pc.sh` | Publishes the committed page and service files to the PC: only the files that differ, the task restarted when server code changed, then a check that the page answers (see below) |
| `install-on-windows.ps1` | Run once, in an administrator PowerShell: adds the firewall rule, then registers and starts the task *Spending Analysis web page*. The task runs at boot as the PC's account (S4U, no stored password), with `pythonw` and `--log spending_web.log` |

## On the PC

It's installed at `C:\Users\calla\MxServices\Services\` with the repository's layout: `spending-web\` plus
`accounts\spending.py` and `accounts\bank.py`. Those are copies, not a git clone. **Publishing is part of releasing
MxAcctMGR:**

```bash
Services/spending-web/publish-to-pc.sh             # publish what is committed (HEAD)
Services/spending-web/publish-to-pc.sh --dry-run   # only list what would change
```

The script works like this:
1. It exports the page's files and `accounts/spending.py` / `bank.py` from git, so uncommitted edits never go out (it
   says when there are some).
2. It compares them with the PC's copies by SHA-256 and copies only the ones that differ.
3. It restarts the task *Spending Analysis web page* when server code (`.py`) changed. Page files (`static/`) need
   only a reload in the browser.
4. It asks the server on the PC for `/api/setup` with the PC's own key, so the key never leaves the PC. If the page
   doesn't answer, it exits with an error.
5. It writes the commit it published to `spending-web\published.txt` on the PC; the next run shows it.

It never touches `spending_web.local.json`. The link stays the same. The log is
`C:\Users\calla\MxServices\Services\spending-web\spending_web.log`.

To set it up on another machine:
1. Apply V039.
2. Give the role a login: `ALTER ROLE spending_web LOGIN PASSWORD '…'`.
3. Write `spending_web.local.json`.
4. Run `install-on-windows.ps1`. Elsewhere, run `python3 spending_web.py` under any process manager.
