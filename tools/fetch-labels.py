#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Keep the NIIMBOT label catalogue: docs/labels/catalogue.json, the copy the
binary embeds in src/catalogue.json, and the page docs/labels/README.md.

The vendor cloud groups its label templates by series and page size, and counts
them by the barcode an RFID tag on the roll carries. A refresh walks the size
list, queries each size in both orientations, and keeps one record per barcode.

A roll can carry a barcode that listing does not hold. The server saves the
rolls the cloud answered for in `.niimbench.rolls.json`; `--add` asks the
cloud for each one's full record, keeps it in docs/labels/added.json, and
writes it into the catalogue. A refresh keeps the added rows the listing lacks.

    uv run tools/fetch-labels.py                    refresh from the cloud
    uv run tools/fetch-labels.py --add FILE|BARCODE add saved rolls, or barcodes
    uv run tools/fetch-labels.py --write            rewrite the copy and the page
    uv run tools/fetch-labels.py --check            the files agree

No key and no account: the endpoints are the ones the phone app uses. Every
file is written sorted by size and then barcode, so the same answers write the
same bytes.
"""

import json
import pathlib
import sys
import time
import urllib.request

BASE = "https://print.niimbot.com"
HEADERS = {
    "niimbot-user-agent": "AppVersionName/999.0.0",
    "Content-Type": "application/json",
}
PAGE = 100
PAUSE = 0.15

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "docs/labels/catalogue.json"
ADDED = ROOT / "docs/labels/added.json"
EMBEDDED = ROOT / "src/catalogue.json"
PAGE_MD = ROOT / "docs/labels/README.md"

PAPER = {1: "gap", 2: "black", 5: "transparent", 10: "black mark gap"}


def get(path):
    request = urllib.request.Request(BASE + path, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=40) as response:
        return json.loads(response.read())


def post(path, body):
    request = urllib.request.Request(
        BASE + path, data=json.dumps(body).encode(), headers=HEADERS
    )
    with urllib.request.urlopen(request, timeout=40) as response:
        return json.loads(response.read())


def name_in(names, language):
    for entry in names:
        if entry.get("languageCode") == language and entry.get("name"):
            return entry["name"]
    return ""


def collect():
    sizes = get("/api/industryTemplate/sizes")["data"]
    queries = []
    for series in sizes:
        for size in series.get("sizes", []):
            for pair in ((size["width"], size["height"]), (size["height"], size["width"])):
                if pair not in queries:
                    queries.append(pair)

    records = {}
    for width, height in queries:
        page = 1
        while True:
            answer = post(
                "/api/industryTemplate/page",
                {
                    "languageCode": "en",
                    "width": width,
                    "height": height,
                    "limit": PAGE,
                    "page": page,
                },
            )
            body = answer.get("data") or {}
            items = body.get("list") or []
            for item in items:
                barcode = item.get("barcode")
                if barcode:
                    records[barcode] = item
            if not items or page * PAGE >= body.get("total", 0):
                break
            page += 1
        time.sleep(PAUSE)
        print(f"  {width}x{height}: {len(records)} labels so far", file=sys.stderr)

    return records.values()


def row(item):
    names = item.get("names") or []
    profile = item.get("profile") or {}
    machines = [m for m in (profile.get("machineName") or "").split(",") if m]
    ours = []
    for tag in ("B1", "B18", "B21", "D11", "D110"):
        if any(m == tag or m.startswith(tag + "_") or m == tag + "S" for m in machines):
            ours.append(tag.lower())
    return {
        "barcode": item.get("barcode", ""),
        "name": name_in(names, "en") or item.get("name", ""),
        "name_zh": name_in(names, "zh-cn"),
        "width_mm": whole(item.get("width")),
        "height_mm": whole(item.get("height")),
        "paper_type": item.get("paperType"),
        "consumable_type": item.get("consumableType"),
        "machines": machines,
        "ours": ours,
    }


def whole(mm):
    """A size in whole millimetres, as the binary reads it."""
    return round(mm) if isinstance(mm, float) else mm


def ordered(rows):
    return sorted(rows, key=lambda r: (r["width_mm"] or 0, r["height_mm"] or 0, r["barcode"]))


def merged(rows, extra):
    """`rows` and the rows of `extra` whose barcode `rows` lacks."""
    held = {r["barcode"] for r in rows}
    return list(rows) + [r for r in extra if r["barcode"] not in held]


def read(path):
    return json.loads(path.read_text()) if path.exists() else []


def lines(rows):
    """One row per line, so a change to the catalogue diffs as the rows it touched."""
    body = ",\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rows)
    return "[\n" + body + "\n]\n"


def page(rows):
    sizes = []
    by_size = {}
    for r in rows:
        size = (r["width_mm"], r["height_mm"])
        if size not in by_size:
            sizes.append(size)
            by_size[size] = []
        by_size[size].append(r)
    bench = sum(1 for size in sizes if any(r["ours"] for r in by_size[size]))
    added = len(read(ADDED))

    out = [
        "# Label catalogue",
        "",
        "Every label the vendor cloud offers in the sizes its own template endpoint groups by series, keyed on the barcode an RFID tag carries, and the rolls added from a tag the cloud answered for. The app reads a roll's barcode from the tag and looks it up here to size the canvas, so this page is the reference for what a roll can be, and `catalogue.json` beside it is the same data for code to read.",
        "",
        "`catalogue.json` and this page are written by [tools/fetch-labels.py](../../tools/fetch-labels.py); do not edit either by hand. [Regenerating](#regenerating) says how.",
        "",
        "## Coverage",
        "",
        "| Sizes | Labels | Added from a tag | Sizes a bench model takes |",
        "|---|---|---|---|",
        f"| {len(sizes)} | {len(rows)} | {added} | {bench} |",
        "",
        "The printer heads this bench drives take these label widths: 12, 14 and 15 mm on the D-series, 20 to 50 mm on the B-series, and 10 to 14 mm on the B18. A catalogue entry names the machines the vendor ships it for; the `bench` column below only says that one of this bench's heads appears in that list.",
        "",
        "## Labels by size",
        "",
        "`paper` is the vendor's paper type for the roll; niimbench does not send it and always tells the printer label type 1, a gap label, and `bench` lists the models here that the vendor lists the label for. A dash in `bench` means no model this bench drives is on the label's machine list, but the size may still be printable if a roll measures that way.",
    ]
    for width, height in sizes:
        out += ["", f"### {width}x{height} mm", "", "| Barcode | Name | Paper | Bench |", "|---|---|---|---|"]
        for r in by_size[(width, height)]:
            name = (r["name"] or r["name_zh"]).replace("|", "\\|")
            paper = PAPER.get(r["paper_type"], str(r["paper_type"]))
            out.append(f"| `{r['barcode']}` | {name} | {paper} | {', '.join(r['ours']) or '—'} |")
    out += [
        "",
        "## Regenerating",
        "",
        "Refresh the whole catalogue from the vendor cloud:",
        "",
        "```sh",
        "make labels",
        "```",
        "",
        "The script walks `industryTemplate/sizes` and then pages through `industryTemplate/page` for each size in both orientations. It needs no key and no account. It also writes `src/catalogue.json`, the copy the binary embeds, and this page, so the table the code reads and this one cannot drift apart. The rows in `added.json` that the listing lacks are kept.",
        "",
        "Add the rolls a server saved from the cloud, from `.niimbench.rolls.json` in the folder it runs from:",
        "",
        "```sh",
        "make add-rolls",
        "```",
        "",
        "A roll's tag can carry a barcode the listing does not hold: one roll has several. When the server asks the cloud about one, it saves the answer. This asks the cloud for that barcode's full record, keeps it in `added.json`, and writes it into the catalogue. `ROLLS=` names another saved file, such as the app's under `~/.local/state/niimbench` or `~/Library/Application Support/niimbench`, or a barcode.",
        "",
        "Check that the JSON, the embedded copy and this page agree:",
        "",
        "```sh",
        "make labels-check",
        "```",
    ]
    return "\n".join(out) + "\n"


def write(rows):
    rows = ordered(rows)
    CATALOGUE.write_text(lines(rows))
    EMBEDDED.write_text(lines(rows))
    PAGE_MD.write_text(page(rows))
    print(f"{len(rows)} labels", file=sys.stderr)


def barcodes(args):
    """The barcodes named on the command line, or in the saved files named."""
    found = []
    for arg in args:
        path = pathlib.Path(arg).expanduser()
        if path.is_file():
            found += [r["barcode"] for r in json.loads(path.read_text()) if r.get("barcode")]
        elif arg.isdigit():
            found.append(arg)
        else:
            sys.exit(f"{arg}: neither a saved rolls file nor a barcode")
    return found


def add(args):
    rows = read(CATALOGUE)
    held = {r["barcode"] for r in rows}
    new = []
    for barcode in dict.fromkeys(barcodes(args)):
        if barcode in held:
            print(f"  {barcode}: already in the catalogue", file=sys.stderr)
            continue
        item = post("/api/template/getCloudTemplateByOneCode", {"oneCode": barcode}).get("data")
        time.sleep(PAUSE)
        if not item or not item.get("width") or not item.get("height"):
            print(f"  {barcode}: the cloud does not know it", file=sys.stderr)
            continue
        # The tag's barcode, which the binary looks up; the answer's own
        # `barcode` can be another of the same roll's codes.
        found = row(item) | {"barcode": barcode}
        print(f"  {barcode}: {found['width_mm']}x{found['height_mm']} {found['name']}", file=sys.stderr)
        new.append(found)
        held.add(barcode)
    if not new:
        return
    ADDED.write_text(lines(ordered(read(ADDED) + new)))
    write(rows + new)


def check():
    rows = read(CATALOGUE)
    problems = []
    if EMBEDDED.read_text() != CATALOGUE.read_text():
        problems.append(f"{EMBEDDED.relative_to(ROOT)} is not a copy of {CATALOGUE.relative_to(ROOT)}")
    if CATALOGUE.read_text() != lines(ordered(rows)):
        problems.append(f"{CATALOGUE.relative_to(ROOT)} is not sorted one row per line")
    if PAGE_MD.read_text() != page(rows):
        problems.append(f"{PAGE_MD.relative_to(ROOT)} does not match {CATALOGUE.relative_to(ROOT)}")
    held = {r["barcode"] for r in rows}
    missing = [r["barcode"] for r in read(ADDED) if r["barcode"] not in held]
    if missing:
        problems.append(f"rows in added.json missing from the catalogue: {', '.join(missing)}")
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        sys.exit("the label catalogue is out of step; uv run tools/fetch-labels.py --write rewrites it")


def main():
    args = sys.argv[1:]
    if args[:1] == ["--add"]:
        add(args[1:])
    elif args == ["--write"]:
        write(merged(read(CATALOGUE), read(ADDED)))
    elif args == ["--check"]:
        check()
    elif not args:
        write(merged([row(item) for item in collect()], read(ADDED)))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
