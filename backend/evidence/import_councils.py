"""Extract public Council/postcode pairs from the VEC workbook; no population data.

Run: python -m evidence.import_councils PATH_TO_VEC_XLSX
Source and licence are recorded beside the generated JSON.
"""
import json
from pathlib import Path
import re
import sys
from xml.etree import ElementTree
from zipfile import ZipFile


def extract(path):
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    councils = {}
    with ZipFile(path) as book:
        strings = ["".join(node.itertext()) for node in ElementTree.fromstring(book.read("xl/sharedStrings.xml"))]
        for row in ElementTree.fromstring(book.read("xl/worksheets/sheet1.xml")).findall("m:sheetData/m:row", ns):
            values = {}
            for cell in row:
                value = cell.find("m:v", ns)
                values[re.sub(r"[0-9]", "", cell.attrib["r"])] = (
                    strings[int(value.text)] if cell.get("t") == "s" else value.text if value is not None else "")
            name, postcode = values.get("C", ""), values.get("B", "")
            if name.endswith("Council") and re.fullmatch(r"[0-9]{4}", postcode):
                councils.setdefault(name, set()).add(postcode)
    if len(councils) != 79:
        raise ValueError("Expected all 79 Victorian councils; inspect the workbook before replacing data.")
    return [{"id": re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-"),
             "name": name, "postcodes": sorted(postcodes)} for name, postcodes in sorted(councils.items())]


if __name__ == "__main__":
    rows = extract(sys.argv[1])
    Path(__file__).with_name("councils.json").write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    print(f"Saved {len(rows)} councils with {sum(len(row['postcodes']) for row in rows)} postcode matches.")
