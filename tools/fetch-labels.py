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

import collections
import json
import math
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


ALIASES = ("amazonCodeBeijing", "amazonCodeWuhan", "sparedCode", "virtualBarCode")


def codes(item):
    """The other barcodes the vendor gives the same roll, any of which its tag
    may carry."""
    extrain = (item.get("profile") or {}).get("extrain") or {}
    found = {extrain.get(k) for k in ALIASES}
    found |= {v for k, v in (extrain.get("barcodeCategoryMap") or {}).items() if k != "materialModelSn"}
    return {c for c in found if isinstance(c, str) and c.isdigit() and c != item.get("barcode")}


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
    """A size in whole millimetres, as the binary reads it, a half rounded up
    as the server rounds a cloud answer: a 12.5 mm label is laid out as 13."""
    return math.floor(mm + 0.5) if isinstance(mm, float) else mm


def ordered(rows):
    return sorted(rows, key=lambda r: (r["width_mm"] or 0, r["height_mm"] or 0, r["barcode"]))


def held(rows):
    """Every code the catalogue answers for: each row's barcode and its others."""
    return {c for r in rows for c in [r["barcode"], *r.get("codes", [])]}


def merged(rows, extra):
    """`rows` and the rows of `extra` whose barcode `rows` does not answer
    for, each with only the codes nothing before it claimed."""
    have = held(rows)
    out = list(rows)
    for r in extra:
        if r["barcode"] in have:
            continue
        r = r | {"codes": sorted(set(r.get("codes", [])) - have)}
        have |= {r["barcode"], *r["codes"]}
        out.append(r)
    return out


def read(path):
    return json.loads(path.read_text()) if path.exists() else []


def lines(rows):
    """One row per line, so a change to the catalogue diffs as the rows it touched."""
    body = ",\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in rows)
    return "[\n" + body + "\n]\n"


def page(rows):
    sizes = {}
    for r in rows:
        sizes.setdefault((r["width_mm"], r["height_mm"]), []).append(r)
    codes_held = sum(len(r.get("codes", [])) for r in rows)
    added = len(read(ADDED))
    models = ("b1", "b18", "b21", "d11", "d110")
    per_model = {m: sum(1 for r in rows if m in r["ours"]) for m in models}

    out = [
        "# Label catalogue",
        "",
        "Every label the vendor cloud offers in the sizes its own template endpoint groups by series, and the rolls added from a tag the cloud answered for, keyed on the barcodes an RFID tag on the roll can carry. The app reads a roll's barcode from the tag and looks it up here to size the canvas, so this is the reference for what a roll can be. [catalogue.json](catalogue.json) beside this page holds every roll; this page counts them.",
        "",
        "`catalogue.json`, the copy the binary embeds and this page are written by [tools/fetch-labels.py](../../tools/fetch-labels.py); do not edit them by hand. [Regenerating](#regenerating) says how.",
        "",
        "## Coverage",
        "",
        "| Rolls | Sizes | Other codes a tag may carry | Added from a tag |",
        "|---|---|---|---|",
        f"| {len(rows)} | {len(sizes)} | {codes_held} | {added} |",
        "",
        "| Model | Rolls listed for it |",
        "|---|---|",
        *[f"| {m} | {per_model[m]} |" for m in models],
        "",
        "A roll counts for a model when the vendor lists it for a B1, B18, B21, D11 or D110, its variants included: a D110_M is a D110 here, and a D11S a D11. A roll listed for none of them is kept, and its size may still be printable if a roll measures that way.",
        "",
        "## A row",
        "",
        "One roll per line of `catalogue.json`:",
        "",
        "| Field | What it is |",
        "|---|---|",
        "| `barcode` | The vendor's barcode for the roll |",
        "| `codes` | Its other barcodes, any of which the tag may carry instead: the vendor gives one roll several. Each code names one roll |",
        "| `name`, `name_zh` | The vendor's English and Chinese names |",
        "| `width_mm`, `height_mm` | The size as the vendor lists it, in whole millimetres, a half rounded up. Some rolls are listed length first, 40x12 for a 12 mm roll of 40 mm labels; the server turns those to face the head |",
        "| `paper_type` | " + ", ".join(f"{k} {v}" for k, v in PAPER.items()) + "; niimbench does not send it and always tells the printer label type 1, a gap label |",
        "| `consumable_type` | The vendor's consumable kind |",
        "| `machines` | The printers the vendor lists the roll for |",
        "| `ours` | The models this bench drives among them |",
        "",
        "`src/catalogue.json`, the copy the binary embeds, keeps `barcode`, `codes`, `name`, the size and `paper_type`, with the Chinese name where there is no English one.",
        "",
        "## Looking up a roll",
        "",
        "The trace names the barcode a roll's tag answered with. This finds the roll a barcode names, here `6972842743558`; put the trace's barcode in its place:",
        "",
        "```sh",
        "jq -c '.[] | select(.barcode == \"6972842743558\" or (.codes | index(\"6972842743558\")))' docs/labels/catalogue.json",
        "```",
        "",
        "## Sizes",
        "",
        "| Size, mm | Rolls | Models |",
        "|---|---|---|",
    ]
    for (width, height), held in sizes.items():
        ours = sorted({m for r in held for m in r["ours"]}, key=models.index)
        out.append(f"| {width}x{height} | {len(held)} | {', '.join(ours)} |")
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
        "The script walks `industryTemplate/sizes` and then pages through `industryTemplate/page` for each size in both orientations. It needs no key and no account. It keeps one row per barcode and writes the JSON, the embedded copy and this page. The rows in `added.json` whose barcode the listing does not answer for are kept.",
        "",
        "Add the rolls a server saved from the cloud, from `.niimbench.rolls.json` in the folder it runs from:",
        "",
        "```sh",
        "make add-rolls",
        "```",
        "",
        "A tag the catalogue does not know, once the server has asked the cloud about it, is saved there. This asks the cloud for that barcode's full record, keeps it in `added.json`, and writes it into the catalogue. `ROLLS=` names another saved file, such as the app's under `~/.local/state/niimbench` or `~/Library/Application Support/niimbench`, or a barcode.",
        "",
        "Check that the JSON, the embedded copy and this page agree, and that no code names two rolls:",
        "",
        "```sh",
        "make labels-check",
        "```",
    ]
    return "\n".join(out) + "\n"


def embedded(rows):
    """What the binary reads of a row."""
    keys = ("barcode", "codes", "name", "width_mm", "height_mm", "paper_type")
    return [{k: r.get(k, []) for k in keys} | {"name": r["name"] or r["name_zh"]} for r in rows]


def write(rows):
    rows = ordered(rows)
    CATALOGUE.write_text(lines(rows))
    EMBEDDED.write_text(lines(embedded(rows)))
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
    have = held(rows)
    new = []
    for barcode in dict.fromkeys(barcodes(args)):
        if barcode in have:
            print(f"  {barcode}: already in the catalogue", file=sys.stderr)
            continue
        item = post("/api/template/getCloudTemplateByOneCode", {"oneCode": barcode}).get("data")
        time.sleep(PAUSE)
        if not item or not item.get("width") or not item.get("height"):
            print(f"  {barcode}: the cloud does not know it", file=sys.stderr)
            continue
        # The tag's barcode, which the binary looks up; the answer's own
        # `barcode` can be another of the same roll's codes.
        others = (codes(item) | {item.get("barcode") or barcode}) - have - {barcode}
        found = row(item) | {"barcode": barcode, "codes": sorted(others)}
        print(f"  {barcode}: {found['width_mm']}x{found['height_mm']} {found['name']}", file=sys.stderr)
        new.append(found)
        have |= {barcode, *others}
    if not new:
        return
    ADDED.write_text(lines(ordered(read(ADDED) + new)))
    write(rows + new)


def check():
    rows = read(CATALOGUE)
    problems = []
    if EMBEDDED.read_text() != lines(embedded(rows)):
        problems.append(f"{EMBEDDED.relative_to(ROOT)} is not what the binary reads of {CATALOGUE.relative_to(ROOT)}")
    if CATALOGUE.read_text() != lines(ordered(rows)):
        problems.append(f"{CATALOGUE.relative_to(ROOT)} is not sorted one row per line")
    if PAGE_MD.read_text() != page(rows):
        problems.append(f"{PAGE_MD.relative_to(ROOT)} does not match {CATALOGUE.relative_to(ROOT)}")
    have = held(rows)
    missing = [r["barcode"] for r in read(ADDED) if r["barcode"] not in have]
    if missing:
        problems.append(f"rows in added.json missing from the catalogue: {', '.join(missing)}")
    claimed = collections.Counter(c for r in rows for c in [r["barcode"], *r.get("codes", [])])
    twice = sorted(c for c, n in claimed.items() if n > 1)
    if twice:
        problems.append(f"codes that name more than one row: {', '.join(twice[:10])}")
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
