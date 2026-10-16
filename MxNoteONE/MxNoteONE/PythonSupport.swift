//
//  PythonSupport.swift
//  MxNoteONE
//
//  The Python side of notebook scripts, written out where scripts can import
//  it (~/Library/Application Support/MxNoteONE/python):
//
//  • mxnote.py   — the tables of the notebook, from Python: find tables by
//                  name or tag, rows and cells by tag, read and change them.
//                  Changes stream back to MxNoteONE as the script runs.
//  • mxrunner.py — runs a script, or debugs it (breakpoints, step over / into /
//                  out, variables) talking to the Scripts window.
//  • mxcheck.py  — before a run: syntax errors, and imports that aren't
//                  installed (so the window can offer to install them).
//
//  Everything here works with Python 3.9 (the Python that comes with Xcode).
//

import Foundation

enum PythonSupport {
    /// Where the helper modules are written.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MxNoteONE/python")
    }

    /// Writes the helpers (when they've changed).
    static func install() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, source) in [("mxnote.py", mxnote), ("mxrunner.py", runner), ("mxcheck.py", check)] {
            let url = folder.appending(path: name)
            if (try? String(contentsOf: url, encoding: .utf8)) != source {
                try source.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Marker that starts a message from a script to MxNoteONE (on its own line of standard output).
    static let marker = "\u{1E}"

    // MARK: - mxnote.py

    static let mxnote = #"""
"""mxnote — the tables in your MxNoteONE notebook, from Python.

    import mxnote as mx

    inv = mx.table("Inventory")            # a table by its name (or a tag)
    for row in inv.rows:                   # its rows (after the header row)
        if row["Qty"] < 5:                 # a cell by column heading, letter or number
            row["Status"] = "Reorder"      # changes show in the notebook as the script runs
            row.tags.add("low")
    total = sum(t.column("Amount").sum() for t in mx.tables(tag="expenses"))
    mx.cell("grand-total").value = total   # a cell by its tag, anywhere in the notebook

Finding things (every page of the notebook, except locked sections):
    mx.tables(tag=None, name=None, section=None, page=None)    all tables, or those matching
    mx.table("Name or tag")                                    one table
    mx.rows("tag")  mx.cells("tag")  mx.cell("tag")            rows and cells by tag
    mx.find("text", exact=False)                               cells showing some text

A table:   t.name  t.tags  t.page  t.section  t.headers  t.rows  t.row(0) / t.row(tag="total")
           t["B3"]  t["B3"] = 5  t.cell("B3")  t.column("Amount")  t.records()  t.values()
           t.append({"Item": "Pens", "Qty": 3})  t.insert(0, [...])  t.delete(row)  t.add_column("Notes")
           t.to_pandas()  (needs pandas)
A row:     row["Qty"]  row["Qty"] = 4  row.cell("Qty")  row.values  row.tags  row.delete()
A cell:    cell.value  cell.text  cell.formula  cell.ref  cell.tags  (cell.value = 12, cell.formula = "=SUM(B2:B9)")
A column:  col.values()  col.numbers()  col.sum()  col.cells  col.header

Formulas are worked out again by MxNoteONE after they change, so a formula's value read in the same run
can be the one from before the script started.
"""
import json
import os
import re
import sys
import datetime

__all__ = ["tables", "table", "rows", "cells", "cell", "find", "notebook_name", "Table", "Row", "Cell", "Column"]

_STREAM = sys.__stdout__
_MARK = "\x1e"


def _send(kind, payload):
    _STREAM.write(_MARK + kind + " " + json.dumps(payload) + "\n")
    _STREAM.flush()


_tables = None
_notebook = {}


def _load():
    global _tables, _notebook
    if _tables is None:
        path = os.environ.get("MXNOTE_SNAPSHOT")
        if not path or not os.path.exists(path):
            raise RuntimeError("mxnote works in scripts run from MxNoteONE (Window ▸ Notebook Scripts).")
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        _notebook = data.get("notebook", {})
        _tables = [Table(t) for t in data.get("tables", [])]
    return _tables


def notebook_name():
    """The notebook's name."""
    _load()
    return _notebook.get("name", "")


def _norm(tag):
    return str(tag).strip().lstrip("#").lower()


def tables(tag=None, name=None, section=None, page=None):
    """Every table in the notebook, or those with a tag, a name, in a section, or on a page."""
    found = []
    for t in _load():
        if tag is not None and _norm(tag) not in t.tags:
            continue
        if name is not None and (t.name or "").lower() != str(name).lower():
            continue
        if section is not None and t.section.lower() != str(section).lower():
            continue
        if page is not None and t.page.lower() != str(page).lower():
            continue
        found.append(t)
    return found


def table(key):
    """A table by its name (not case-sensitive), else the first with the tag."""
    for t in _load():
        if t.name and t.name.lower() == str(key).lower():
            return t
    for t in _load():
        if _norm(key) in t.tags:
            return t
    names = sorted(t.name for t in _load() if t.name)
    raise LookupError("No table named or tagged %r. Named tables: %s" % (key, ", ".join(names) or "none yet — name one with "
                      "Table ▸ Name & Tags in MxNoteONE"))


def rows(tag):
    """Every row tagged `tag`, in every table."""
    return [r for t in _load() for r in t.all_rows if _norm(tag) in r.tags]


def cells(tag):
    """Every cell tagged `tag`, in every table."""
    found = []
    for t in _load():
        for key, tags in list(t._cell_tags.items()):
            if _norm(tag) in tags:
                r, c = (int(x) for x in key.split(","))
                found.append(Cell(t, t._key_at(r), c))
    return found


def cell(tag):
    """The cell tagged `tag` (the first, if there are several)."""
    found = cells(tag)
    if not found:
        raise LookupError("No cell is tagged %r. Tag one with right-click ▸ Name & Tags ▸ Tag Cells in MxNoteONE." % tag)
    return found[0]


def find(text, exact=False):
    """Cells showing `text` (or exactly `text`), in every table."""
    text = str(text)
    found = []
    for t in _load():
        for r in range(t.row_count):
            for c in range(t.column_count):
                shown = t._shown[r][c]
                if (shown == text) if exact else (text.lower() in shown.lower()):
                    found.append(Cell(t, t._key_at(r), c))
    return found


_NUMBER = re.compile(r"^\s*([-+]?)\s*[$€£¥]?\s*([-+]?)(\d{1,3}(?:,\d{3})+|\d*)(\.\d+)?\s*(%?)\s*$")


def _number(text):
    m = _NUMBER.match(text or "")
    if not m or (not m.group(3) and not m.group(4)):
        return None
    sign = -1 if "-" in (m.group(1) + m.group(2)) else 1
    value = float((m.group(3) or "0").replace(",", "") + (m.group(4) or ""))
    return sign * value / (100 if m.group(5) else 1)


def _format(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if value.is_integer() and abs(value) < 1e15:
            return str(int(value))
        return format(value, ".12g")
    if isinstance(value, datetime.datetime):
        return value.strftime("%Y-%m-%d %H:%M")
    if isinstance(value, datetime.date):
        return value.isoformat()
    return str(value)


def _letters(i):
    s = ""
    i += 1
    while i > 0:
        i, rem = divmod(i - 1, 26)
        s = chr(65 + rem) + s
    return s


def _column_number(letters):
    n = 0
    for ch in letters.upper():
        n = n * 26 + (ord(ch) - 64)
    return n - 1


class Tags(object):
    """Tags (lower case, without #): add, remove, `in`, iterate."""

    def __init__(self, items, changed):
        self._items = [_norm(t) for t in (items or [])]
        self._changed = changed

    def add(self, *tags):
        for t in tags:
            t = _norm(t)
            if t and t not in self._items:
                self._items.append(t)
        self._changed(list(self._items))

    def remove(self, *tags):
        for t in tags:
            t = _norm(t)
            if t in self._items:
                self._items.remove(t)
        self._changed(list(self._items))

    discard = remove

    def clear(self):
        self._items = []
        self._changed([])

    def __contains__(self, tag):
        return _norm(tag) in self._items

    def __iter__(self):
        return iter(list(self._items))

    def __len__(self):
        return len(self._items)

    def __repr__(self):
        return "{" + ", ".join("#" + t for t in self._items) + "}"


class Table(object):
    """A table on a page of the notebook."""

    def __init__(self, d):
        self.id = d["id"]
        self.page = d.get("page", "")
        self.section = d.get("section", "")
        self.header_row = bool(d.get("headerRow", True))
        self._name = d.get("name")
        self._rows = d.get("rows") or [[]]
        self._shown = d.get("shown") or [list(r) for r in self._rows]
        self._numbers = d.get("numbers") or [[_number(x) for x in r] for r in self._rows]
        self._row_tags = {int(k): [_norm(t) for t in v] for k, v in (d.get("rowTags") or {}).items()}
        self._cell_tags = {k: [_norm(t) for t in v] for k, v in (d.get("cellTags") or {}).items()}
        self._tags = [_norm(t) for t in (d.get("tags") or [])]
        # Rows keep who they are while rows are added and deleted.
        self._keys = list(range(len(self._rows)))
        self._next_key = len(self._rows)

    # Where it is, what it's called

    @property
    def name(self):
        return self._name

    @name.setter
    def name(self, value):
        self._name = None if value is None else str(value)
        _send("MXOP", {"op": "table", "t": self.id, "name": self._name or ""})

    @property
    def tags(self):
        def changed(items):
            self._tags = items
            _send("MXOP", {"op": "table", "t": self.id, "tags": items})
        return Tags(self._tags, changed)

    def __repr__(self):
        label = repr(self._name) if self._name else "(unnamed)"
        return "<Table %s on page %r, %d×%d>" % (label, self.page, self.row_count, self.column_count)

    # Size, headings

    @property
    def row_count(self):
        return len(self._rows)

    @property
    def column_count(self):
        return len(self._rows[0]) if self._rows else 0

    @property
    def _first(self):
        return 1 if self.header_row else 0

    @property
    def headers(self):
        """The header row's texts (column letters when the table has no header row)."""
        if self.header_row and self._rows:
            return [self._shown[0][c] or _letters(c) for c in range(self.column_count)]
        return [_letters(c) for c in range(self.column_count)]

    def _column(self, key):
        if isinstance(key, int):
            if not -self.column_count <= key < self.column_count:
                raise IndexError("Column %d is outside the table (it has %d)" % (key, self.column_count))
            return key % self.column_count
        text = str(key).strip()
        heads = [h.strip().lower() for h in self.headers]
        if self.header_row and text.lower() in heads:
            return heads.index(text.lower())
        if re.match(r"^[A-Za-z]{1,3}$", text):
            c = _column_number(text)
            if c < self.column_count:
                return c
        raise KeyError("No column %r in table %s. Columns: %s" % (key, self._name or self.page, ", ".join(self.headers)))

    def _key_at(self, index):
        return self._keys[index]

    def _index_of(self, key):
        try:
            return self._keys.index(key)
        except ValueError:
            raise LookupError("That row has been deleted")

    # Rows, columns, cells

    @property
    def rows(self):
        """The rows after the header row."""
        return [Row(self, self._keys[r]) for r in range(self._first, self.row_count)]

    @property
    def all_rows(self):
        """Every row, the header row too."""
        return [Row(self, k) for k in self._keys]

    def row(self, index=None, tag=None):
        """A row: by number among the rows after the header (0 = the first), or the first with a tag."""
        if tag is not None:
            for r in self.all_rows:
                if _norm(tag) in r.tags:
                    return r
            raise LookupError("No row tagged %r in table %s" % (tag, self._name or self.page))
        return self.rows[index]

    def column(self, key):
        """A column, by heading, letter (\"B\") or number (0 = the first)."""
        return Column(self, self._column(key))

    def cell(self, ref, column=None):
        """A cell: cell(\"B3\") as on the sheet (row 1 is the table's first row), or cell(row, column) from 0."""
        if column is None:
            m = re.match(r"^\s*([A-Za-z]{1,3})(\d+)\s*$", str(ref))
            if not m:
                raise KeyError("A cell is written like \"B3\"")
            r, c = int(m.group(2)) - 1, _column_number(m.group(1))
        else:
            r, c = int(ref), self._column(column)
        if not (0 <= r < self.row_count and 0 <= c < self.column_count):
            raise IndexError("Cell %s is outside the table (%d rows × %d columns)" % (ref, self.row_count, self.column_count))
        return Cell(self, self._keys[r], c)

    def __getitem__(self, ref):
        if isinstance(ref, tuple):
            return self.cell(ref[0], ref[1]).value
        return self.cell(ref).value

    def __setitem__(self, ref, value):
        if isinstance(ref, tuple):
            self.cell(ref[0], ref[1]).value = value
        else:
            self.cell(ref).value = value

    def __iter__(self):
        return iter(self.rows)

    def __len__(self):
        return self.row_count - self._first

    def values(self, header=False):
        """The cells' values, row by row (with the header row if header=True)."""
        start = 0 if header else self._first
        return [[Cell(self, self._keys[r], c).value for c in range(self.column_count)] for r in range(start, self.row_count)]

    def records(self):
        """The rows as dictionaries, heading → value."""
        heads = self.headers
        return [dict(zip(heads, row)) for row in self.values()]

    def to_pandas(self):
        """The table as a pandas DataFrame (pandas must be installed — the Scripts window offers to)."""
        import pandas
        return pandas.DataFrame(self.values(), columns=self.headers)

    # Changing the table

    def _row_texts(self, values, named):
        texts = [""] * self.column_count
        if isinstance(values, dict):
            named = dict(values, **named)
            values = None
        if values is not None:
            for c, v in enumerate(list(values)[: self.column_count]):
                texts[c] = _format(v)
        for k, v in named.items():
            texts[self._column(k)] = _format(v)
        return texts

    def insert(self, index, values=None, **named):
        """Inserts a row before row `index` (0 = the first row after the header); values as a list or by heading."""
        at = self._first + max(0, min(int(index), len(self)))
        texts = self._row_texts(values, named)
        self._rows.insert(at, list(texts))
        self._shown.insert(at, list(texts))
        self._numbers.insert(at, [_number(t) for t in texts])
        key = self._next_key
        self._next_key += 1
        self._keys.insert(at, key)
        self._shift_tags(at, 1)
        _send("MXOP", {"op": "insertRow", "t": self.id, "at": at, "texts": texts})
        return Row(self, key)

    def append(self, values=None, **named):
        """Adds a row at the bottom; values as a list or by heading: append({"Item": "Pens", "Qty": 3})."""
        return self.insert(len(self), values, **named)

    def delete(self, row):
        """Deletes a row (a Row, or its number among the rows after the header)."""
        r = self._index_of(row._key) if isinstance(row, Row) else self._first + int(row)
        if self.row_count <= 1:
            raise ValueError("A table keeps at least one row")
        del self._rows[r], self._shown[r], self._numbers[r], self._keys[r]
        self._shift_tags(r, -1)
        _send("MXOP", {"op": "deleteRow", "t": self.id, "r": r})

    def add_column(self, header="", values=None, at=None):
        """Adds a column (at the end, or before column `at`), with a heading and values for the rows."""
        c = self.column_count if at is None else self._column(at)
        texts = [""] * self.row_count
        if self.header_row and self.row_count:
            texts[0] = _format(header)
        for i, v in enumerate(list(values or [])):
            r = self._first + i
            if r < self.row_count:
                texts[r] = _format(v)
        for r in range(self.row_count):
            self._rows[r].insert(c, texts[r])
            self._shown[r].insert(c, texts[r])
            self._numbers[r].insert(c, _number(texts[r]))
        moved = {}
        for key, tags in self._cell_tags.items():
            rr, cc = (int(x) for x in key.split(","))
            moved["%d,%d" % (rr, cc + 1 if cc >= c else cc)] = tags
        self._cell_tags = moved
        _send("MXOP", {"op": "insertColumn", "t": self.id, "at": c, "texts": texts})
        return Column(self, c)

    def _shift_tags(self, at, delta):
        moved = {}
        for r, tags in self._row_tags.items():
            if delta < 0 and r == at:
                continue
            moved[r + delta if r >= at + (1 if delta < 0 else 0) else r] = tags
        self._row_tags = moved
        cells = {}
        for key, tags in self._cell_tags.items():
            r, c = (int(x) for x in key.split(","))
            if delta < 0 and r == at:
                continue
            cells["%d,%d" % (r + delta if r >= at + (1 if delta < 0 else 0) else r, c)] = tags
        self._cell_tags = cells

    def _set(self, r, c, value):
        text = _format(value)
        self._rows[r][c] = text
        self._shown[r][c] = text
        self._numbers[r][c] = None if text.startswith("=") else _number(text)
        _send("MXOP", {"op": "set", "t": self.id, "r": r, "c": c, "text": text})


class Row(object):
    """A row of a table."""

    def __init__(self, table, key):
        self.table = table
        self._key = key

    @property
    def index(self):
        """Where the row is in the table (0 = the table's first row, the header row if it has one)."""
        return self.table._index_of(self._key)

    def __getitem__(self, column):
        return self.cell(column).value

    def __setitem__(self, column, value):
        self.cell(column).value = value

    def cell(self, column):
        return Cell(self.table, self._key, self.table._column(column))

    @property
    def cells(self):
        return [Cell(self.table, self._key, c) for c in range(self.table.column_count)]

    @property
    def values(self):
        """heading → value."""
        return dict(zip(self.table.headers, [c.value for c in self.cells]))

    @property
    def tags(self):
        def changed(items):
            r = self.index
            if items:
                self.table._row_tags[r] = items
            else:
                self.table._row_tags.pop(r, None)
            _send("MXOP", {"op": "rowTags", "t": self.table.id, "r": r, "tags": items})
        return Tags(self.table._row_tags.get(self.index, []), changed)

    def delete(self):
        self.table.delete(self)

    def __iter__(self):
        return iter(c.value for c in self.cells)

    def __repr__(self):
        return "<Row %d of %s: %r>" % (self.index + 1, self.table._name or "table", self.values)


class Cell(object):
    """A cell of a table."""

    def __init__(self, table, key, column):
        self.table = table
        self._key = key
        self.column = column

    @property
    def row(self):
        return Row(self.table, self._key)

    @property
    def _r(self):
        return self.table._index_of(self._key)

    @property
    def ref(self):
        """Its name on the sheet, like "B3"."""
        return "%s%d" % (_letters(self.column), self._r + 1)

    @property
    def text(self):
        """What's typed in it (a formula's text for a formula)."""
        return self.table._rows[self._r][self.column]

    @property
    def shown(self):
        """What it shows (a formula's result, a number as formatted)."""
        return self.table._shown[self._r][self.column]

    @property
    def value(self):
        """A number for numbers (and formula results), else its text."""
        n = self.table._numbers[self._r][self.column]
        if n is not None:
            return int(n) if float(n).is_integer() and abs(n) < 1e15 else n
        return self.shown

    @value.setter
    def value(self, value):
        self.table._set(self._r, self.column, value)

    @property
    def formula(self):
        t = self.text
        return t if t.startswith("=") else None

    @formula.setter
    def formula(self, formula):
        formula = str(formula)
        self.table._set(self._r, self.column, formula if formula.startswith("=") else "=" + formula)

    @property
    def tags(self):
        def changed(items):
            key = "%d,%d" % (self._r, self.column)
            if items:
                self.table._cell_tags[key] = items
            else:
                self.table._cell_tags.pop(key, None)
            _send("MXOP", {"op": "cellTags", "t": self.table.id, "r": self._r, "c": self.column, "tags": items})
        return Tags(self.table._cell_tags.get("%d,%d" % (self._r, self.column), []), changed)

    def __repr__(self):
        return "<Cell %s of %s: %r>" % (self.ref, self.table._name or "table", self.value)


class Column(object):
    """A column of a table (its cells after the header row)."""

    def __init__(self, table, index):
        self.table = table
        self.index = index

    @property
    def header(self):
        return self.table.headers[self.index]

    @property
    def cells(self):
        return [Cell(self.table, self.table._keys[r], self.index) for r in range(self.table._first, self.table.row_count)]

    def values(self):
        return [c.value for c in self.cells]

    def numbers(self):
        """The numbers in the column (text and empty cells left out)."""
        return [v for v in self.values() if isinstance(v, (int, float)) and not isinstance(v, bool)]

    def sum(self):
        return sum(self.numbers())

    def set(self, values):
        """Writes values down the column, from the first row after the header."""
        for c, v in zip(self.cells, values):
            c.value = v

    def __iter__(self):
        return iter(self.values())

    def __repr__(self):
        return "<Column %s of %s>" % (self.header, self.table._name or "table")
"""#

    // MARK: - mxrunner.py

    static let runner = #"""
"""Runs a notebook script for MxNoteONE, or debugs it (breakpoints, stepping, variables)."""
import bdb
import json
import os
import sys
import traceback
import types

_STREAM = sys.__stdout__


def _send(kind, payload):
    _STREAM.write("\x1e" + kind + " " + json.dumps(payload) + "\n")
    _STREAM.flush()


def _show(value):
    try:
        text = repr(value)
    except Exception:
        text = "<%s>" % type(value).__name__
    return text if len(text) <= 300 else text[:297] + "..."


class Debugger(bdb.Bdb):
    def __init__(self, script, breakpoints):
        bdb.Bdb.__init__(self)
        self.script = script
        self.first = True
        self.has_breakpoints = bool(breakpoints)
        for line in breakpoints:
            self.set_break(script, int(line))

    def stop_here(self, frame):
        # Only the script's own lines: stepping goes over library code.
        if os.path.abspath(frame.f_code.co_filename) != self.script:
            return False
        return bdb.Bdb.stop_here(self, frame)

    def user_line(self, frame):
        if self.first:
            self.first = False
            if self.has_breakpoints:
                # Run to the first breakpoint.
                self.set_continue()
                return
        self.interaction(frame)

    def interaction(self, frame):
        stack = []
        f = frame
        while f is not None:
            if os.path.abspath(f.f_code.co_filename) == self.script:
                stack.append({"function": f.f_code.co_name, "line": f.f_lineno})
            f = f.f_back
        names = {}
        for name, value in frame.f_locals.items():
            if name.startswith("__") or isinstance(value, types.ModuleType):
                continue
            if isinstance(value, (types.FunctionType, type)) and frame.f_code.co_name == "<module>":
                continue
            names[name] = {"type": type(value).__name__, "value": _show(value)}
        _send("MXDBG", {"line": frame.f_lineno, "function": frame.f_code.co_name, "locals": names, "stack": stack})
        while True:
            command = sys.stdin.readline()
            if not command:
                self.set_quit()
                return
            command = command.strip()
            if command == "continue":
                self.set_continue()
                return
            if command == "next":
                self.set_next(frame)
                return
            if command == "step":
                self.set_step()
                return
            if command == "return":
                self.set_return(frame)
                return
            if command == "quit":
                self.set_quit()
                return
            if command.startswith("eval "):
                expression = command[5:]
                try:
                    _send("MXEVAL", {"expr": expression, "value": _show(eval(expression, frame.f_globals, frame.f_locals))})
                except Exception as e:
                    _send("MXEVAL", {"expr": expression, "error": "%s: %s" % (type(e).__name__, e)})
                continue
            if command.startswith("break "):
                self.clear_all_breaks()
                for line in json.loads(command[6:]):
                    self.set_break(self.script, int(line))
                continue


def main():
    script = os.path.abspath(sys.argv[1])
    debug = os.environ.get("MXNOTE_DEBUG") == "1"
    breakpoints = json.loads(os.environ.get("MXNOTE_BREAKPOINTS") or "[]")
    sys.argv = [script] + sys.argv[2:]
    sys.path.insert(0, os.path.dirname(script))
    with open(script, encoding="utf-8") as f:
        source = f.read()
    status = "finished"
    try:
        code = compile(source, script, "exec")
        scope = {"__name__": "__main__", "__file__": script, "__builtins__": __builtins__}
        if debug:
            Debugger(script, breakpoints).run(code, scope, scope)
        else:
            exec(code, scope, scope)
    except bdb.BdbQuit:
        status = "stopped"
    except SystemExit as e:
        status = "finished" if e.code in (None, 0) else "error"
    except KeyboardInterrupt:
        status = "stopped"
    except BaseException as e:
        status = "error"
        frames = [fr for fr in traceback.extract_tb(e.__traceback__) if os.path.abspath(fr.filename) == script]
        line = frames[-1].lineno if frames else getattr(e, "lineno", None)
        # The traceback from the script's own code on (not the runner's).
        tb = e.__traceback__
        while tb is not None and os.path.abspath(tb.tb_frame.f_code.co_filename) != script:
            tb = tb.tb_next
        sys.stderr.write("".join(traceback.format_exception(type(e), e, tb or None)))
        sys.stderr.flush()
        if isinstance(e, ModuleNotFoundError) and e.name:
            _send("MXMISSING", {"module": e.name.split(".")[0]})
        _send("MXERROR", {"line": line, "message": "%s: %s" % (type(e).__name__, e)})
    sys.stdout.flush()
    _send("MXEND", {"status": status})


if __name__ == "__main__":
    main()
"""#

    // MARK: - mxcheck.py

    static let check = #"""
"""Before a run: the script's syntax, and the modules it imports that aren't installed."""
import ast
import importlib.util
import json
import sys


def main():
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        source = f.read()
    try:
        tree = ast.parse(source, path)
    except SyntaxError as e:
        print(json.dumps({"syntaxError": {"line": e.lineno, "message": e.msg}}))
        return
    modules = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                modules.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            modules.add(node.module.split(".")[0])
    modules.discard("mxnote")
    missing = []
    for name in sorted(modules):
        try:
            if importlib.util.find_spec(name) is None:
                missing.append(name)
        except (ImportError, ValueError):
            missing.append(name)
    print(json.dumps({"imports": sorted(modules), "missing": missing, "version": sys.version.split()[0]}))


if __name__ == "__main__":
    main()
"""#
}
