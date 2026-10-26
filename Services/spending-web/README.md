# spending-web — Spending Analysis on the home network

MxAcctMGR's **Reporting ▸ Spending Analysis** as a read-only web page for the rest of the family. It shows the same
numbers and tabs, but nothing on it can change the data. Each section, purchase and rule has a way to send John a note.
The notes land in the security master (`srm.spending_feedback`, V039). MxAcctMGR's **Feedback** tab shows them, with
a status and a reply that the page shows back under **My Notes**.

It runs on **K3JDR-DSKTOP-11** (192.168.0.223), next to the security master, so the page is up whenever the PC is,
whether or not the Mac is on.

## The link

`http://192.168.0.223:8780/s/<key>/`, or `http://k3jdr-dsktop-11.local:8780/s/<key>/`. The key is in
`spending_web.local.json` on the PC. Anyone who has the link and is on the home network can open the page:

- **Home network only.** Windows Firewall opens port 8780 to the local subnet on the Private profile only. The server
  also answers only addresses in `allow` (192.168.0.0/24, the PC itself, and IPv6 link-local, which is how a Mac reaches
  `*.local`).
- **Secret path.** Without the key, every path is a bare 404, so the page gives no hint that it exists. The key never
  goes to the server's log, and pages are sent with `Referrer-Policy: no-referrer`.
- **Read-only login.** The server signs in as `spending_web` (V039). That login can read what the page shows and add
  notes, and nothing else. It sees target accounts by name only: their logons and addresses are not readable. Its
  password exists only in the PC's config file, readable by the PC account, SYSTEM and Administrators.
- To revoke the link, put a new key in the config (`python spending_web.py --new-key`) and restart the task. The old
  link then stops working.

## What the page has

The tabs are Attribution, Deep Dive, Forward Curve, Entries, Rules, Family & Lifecycle, Sources and My Notes. They show
the same calculations as MxAcctMGR: `static/app.js` ports SpendingEngine (`SpendingModel.swift`). They read the
same queries, through `Services/accounts/spending.py`. Viewing choices are allowed and are kept in the browser: the
year, *Year to date*, *Only registers covering both years*, the Deep Dive category, and the entry filters. Nothing that
edits anything is on the page: no tags, rules, sources, family or triggers.

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
| `spending_web.py` | The server: Python standard library and psycopg2. IPv4 and IPv6 on one socket; address and key checks; static files and the API (`/api/setup`, `/api/analysis`, `/api/sources`, `GET` and `POST /api/feedback`). It writes its log to a file when it runs without a console. |
| `static/index.html`, `app.css`, `app.js` | The page: no outside libraries; charts drawn as SVG at each box's width; light and dark; usable at phone width |
| `spending_web.example.json` | The config's shape: copy it to `spending_web.local.json` (not in git) and fill in the key and password |
| `install-on-windows.ps1` | Run once, in an administrator PowerShell: adds the firewall rule, then registers and starts the task *Spending Analysis web page*. The task runs at boot as the PC's account (S4U, no stored password), with `pythonw` and `--log spending_web.log` |

## On the PC

It's installed at `C:\Users\calla\MxServices\Services\` with the repository's layout: `spending-web\` plus
`accounts\spending.py` and `accounts\bank.py`. Those are copies, not a git clone. To update the page, copy the
changed files over the same paths from the Mac, then restart the task:

```bash
scp Services/spending-web/static/* "k3jdr-dsktop-11:C:/Users/calla/MxServices/Services/spending-web/static/"
scp Services/spending-web/spending_web.py "k3jdr-dsktop-11:C:/Users/calla/MxServices/Services/spending-web/"
scp Services/accounts/spending.py Services/accounts/bank.py "k3jdr-dsktop-11:C:/Users/calla/MxServices/Services/accounts/"
ssh k3jdr-dsktop-11 'Stop-ScheduledTask "Spending Analysis web page"; Start-ScheduledTask "Spending Analysis web page"'
```

A page-only change (`static/`) needs no restart: a reload in the browser picks it up. The log is
`C:\Users\calla\MxServices\Services\spending-web\spending_web.log`.

To set it up on another machine:
1. Apply V039.
2. Give the role a login: `ALTER ROLE spending_web LOGIN PASSWORD '…'`.
3. Write `spending_web.local.json`.
4. Run `install-on-windows.ps1`. Elsewhere, run `python3 spending_web.py` under any process manager.
