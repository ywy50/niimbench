#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Keep the NIIMBOT label catalogue: docs/labels/catalogue.json, what the
binary embeds of it in src/catalogue.txt, and the page docs/labels/README.md.

A roll's RFID tag carries a barcode. A refresh sweeps the vendor's listing of
every label paper, in its English and its Chinese views, keeps the rolls for a
printer this bench drives, one row per barcode with the roll's other codes,
and adds the rows of the older size listing the sweep lacks.

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
import http.client
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
EMBEDDED = ROOT / "src/catalogue.txt"
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


# The phone app's own listing: every label paper, and the templates laid out
# on them, in one language's view at a time. English holds the rolls sold
# outside China; the Chinese view holds many more. Past about 7300 rows a
# query answers empty pages, and the server gives up on a query it cannot
# answer in about 3 s, which an unnarrowed Chinese query is, so a view is
# narrowed by height, by industry and by width until each slice fits.
CAP = 7000
INDUSTRIES = (39, 270, 31, 36, 21, 1033, 275)
ALIASES = ("amazonCodeBeijing", "amazonCodeWuhan", "sparedCode", "virtualBarCode")


def std_page(filters, page):
    answer = {}
    for attempt in range(5):
        try:
            answer = post("/api/stdTemplate/page", {"page": page, "limit": PAGE} | filters)
        except (OSError, ValueError, http.client.HTTPException) as err:
            answer = {"message": str(err)}
        if answer.get("code") == 1:
            time.sleep(PAUSE)
            return answer.get("data") or {}
        time.sleep(2 + 2 * attempt)
    sys.exit(f"stdTemplate/page {filters} page {page}: {answer.get('message')}")


# ponytail: a slice is narrowed only by the values the industries and the
# sizes already seen offer, so a row in no industry, about 1 in 1000, or of a
# height no listing shows, is missed when its slice is too big.
def walk(filters, splits, keep):
    first = std_page(filters, 1)
    total = first.get("total") or 0
    if total > CAP and splits:
        (key, values), rest = splits[0], splits[1:]
        for value in values:
            walk(filters | {key: value}, rest, keep)
        return
    if total > CAP:
        print(f"  {filters}: {total} rows, only the first {CAP}", file=sys.stderr)
    for item in first.get("list") or []:
        keep(item)
    for page in range(2, math.ceil(min(total, CAP) / PAGE) + 1):
        for item in std_page(filters, page).get("list") or []:
            keep(item)
    if total:
        print(f"  {filters}: {total}", file=sys.stderr)


def slim(item):
    """What a row is made from, without the template's layout."""
    profile = item.get("profile") or {}
    extrain = profile.get("extrain") or {}
    keys = ("id", "barcode", "name", "names", "width", "height", "paperType", "consumableType")
    return {k: item.get(k) for k in keys} | {
        "profile": {
            "machineName": profile.get("machineName"),
            "extrain": {k: extrain.get(k) for k in ALIASES + ("templateClass", "barcodeCategoryMap")},
        }
    }


def sweep():
    """Every label for a printer this bench drives, from the English and the
    Chinese views, slimmed."""
    items = {}

    def keep(item):
        if item.get("id") and row(item)["ours"]:
            items[item["id"]] = slim(item)

    every = []

    def seen(item):
        every.append((item.get("width"), item.get("height")))
        keep(item)

    walk({"languageCode": "en"}, [("industryId", INDUSTRIES)], seen)
    sizes = get("/api/industryTemplate/sizes")["data"]
    every += [(s["width"], s["height"]) for series in sizes for s in series.get("sizes", [])]
    values = sorted({v for pair in every for v in pair if v})
    for height in values:
        walk({"languageCode": "zh-cn", "height": height}, [("industryId", INDUSTRIES), ("width", values)], keep)
    return items.values()


def codes(item):
    """The other barcodes the vendor gives the same roll, any of which its tag
    may carry."""
    extrain = (item.get("profile") or {}).get("extrain") or {}
    found = {extrain.get(k) for k in ALIASES}
    found |= {v for k, v in (extrain.get("barcodeCategoryMap") or {}).items() if k != "materialModelSn"}
    return {c for c in found if isinstance(c, str) and c.isdigit() and c != item.get("barcode")}


def rows_of(items):
    """One row per barcode, with the other codes that name it. A label paper
    wins over a template laid out on it, a barcode wins over another row's
    alias, and an alias two rows claim goes to the first in order."""
    best = {}
    others = {}
    for item in items:
        barcode = item.get("barcode")
        if not barcode or any(c.isspace() for c in barcode) or not whole(item.get("width") or 0) or not whole(item.get("height") or 0):
            continue
        rank = (((item.get("profile") or {}).get("extrain") or {}).get("templateClass") != 0, item.get("id") or 0)
        if barcode not in best or rank < best[barcode][0]:
            best[barcode] = (rank, item)
        others.setdefault(barcode, set()).update(codes(item))
    rows = ordered([row(item) for _, item in best.values()])
    taken = {r["barcode"] for r in rows}
    for r in rows:
        mine = sorted(others[r["barcode"]] - taken)
        taken.update(mine)
        r["codes"] = mine
    return rows


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
        "Every label roll the vendor's cloud lists for a printer this bench drives, and the rolls added from a tag the cloud answered for, keyed on the barcodes an RFID tag on the roll can carry. The app reads a roll's barcode from the tag and looks it up here to size the canvas, so this is the reference for what a roll can be. [catalogue.json](catalogue.json) beside this page holds every roll; this page counts them.",
        "",
        "`catalogue.json`, what the binary embeds of it and this page are written by [tools/fetch-labels.py](../../tools/fetch-labels.py); do not edit them by hand. [Regenerating](#regenerating) says how.",
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
        "A roll is here when the vendor lists it for a B1, B18, B21, D11 or D110, its variants included: a D110_M is a D110 here, and a D11S a D11.",
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
        "`src/catalogue.txt` is what the binary embeds of it: one roll per line, the barcode, the width and the height, then the other codes, separated by spaces. A lookup needs nothing else, and the text is a fraction of the JSON's size.",
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
        "The script pages through `stdTemplate/page`, the phone app's own listing of every label paper and the templates laid out on them, in the English view and then the Chinese one, which holds many more. A query stops answering past about 7300 rows and gives up after about 3 seconds, so the Chinese view is asked one height at a time, and a height with more rows than that is narrowed by industry and then by width. That is a few thousand requests, under an hour. It needs no key and no account. It keeps the rolls for a printer this bench drives and one row per barcode, a label paper over a template laid out on it. It then walks the older `industryTemplate` listing, by size, for the rows the sweep lacks, keeps the rows in `added.json` whose barcode nothing answers for, and writes the JSON, the embedded text and this page.",
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
    """What the binary reads of the catalogue: per roll, the barcode, the
    width and the height, then the other codes."""
    return "".join(
        " ".join([r["barcode"], str(r["width_mm"]), str(r["height_mm"]), *r.get("codes", [])]) + "\n" for r in rows
    )


def write(rows):
    rows = ordered(rows)
    CATALOGUE.write_text(lines(rows))
    EMBEDDED.write_text(embedded(rows))
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
    if EMBEDDED.read_text() != embedded(rows):
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
        listed = [r for r in (row(item) for item in collect()) if r["ours"]]
        write(merged(merged(rows_of(sweep()), listed), read(ADDED)))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
