"""Minimal .xlsx reader (first worksheet, values only) using the standard library."""

import re
import xml.etree.ElementTree as ET
import zipfile

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def rows(path):
    """Yields each row of the first sheet as a list of strings (None for empty cells)."""
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")).iter(NS + "si"):
                shared.append("".join(t.text or "" for t in si.iter(NS + "t")))
        sheet = ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
    for row in sheet.iter(NS + "row"):
        values = {}
        for c in row.findall(NS + "c"):
            col = re.match(r"[A-Z]+", c.get("r")).group(0)
            index = 0
            for ch in col:
                index = index * 26 + ord(ch) - 64
            v = c.find(NS + "v")
            kind = c.get("t")
            if kind == "inlineStr":
                value = "".join(t.text or "" for t in c.iter(NS + "t"))
            elif v is None:
                value = None
            elif kind == "s":
                value = shared[int(v.text)]
            else:
                value = v.text
            values[index - 1] = value
        width = max(values) + 1 if values else 0
        yield [values.get(i) for i in range(width)]
