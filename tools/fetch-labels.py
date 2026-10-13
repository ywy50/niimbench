#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Fetch the NIIMBOT label catalogue into the shape docs/labels/catalogue.json holds.

The vendor cloud groups its label templates by series and page size, and counts
them by the barcode an RFID tag on the roll carries. This walks the size list,
queries each size in both orientations, and keeps one record per barcode.

    uv run tools/fetch-labels.py > docs/labels/catalogue.json

No key and no account: the endpoint is the one the phone app's template browser
uses. The output is a JSON array sorted by size and then barcode.
"""

import json
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


def compact(items):
    rows = []
    for item in items:
        names = item.get("names") or []
        profile = item.get("profile") or {}
        machines = [m for m in (profile.get("machineName") or "").split(",") if m]
        ours = []
        for tag in ("B1", "B18", "B21", "D11", "D110"):
            if any(m == tag or m.startswith(tag + "_") or m == tag + "S" for m in machines):
                ours.append(tag.lower())
        rows.append(
            {
                "barcode": item.get("barcode", ""),
                "name": name_in(names, "en") or item.get("name", ""),
                "name_zh": name_in(names, "zh-cn"),
                "width_mm": item.get("width"),
                "height_mm": item.get("height"),
                "paper_type": item.get("paperType"),
                "consumable_type": item.get("consumableType"),
                "machines": machines,
                "ours": ours,
            }
        )
    rows.sort(key=lambda r: (r["width_mm"] or 0, r["height_mm"] or 0, r["barcode"]))
    return rows


def main():
    rows = compact(collect())
    json.dump(rows, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    print(f"\n{len(rows)} labels", file=sys.stderr)


if __name__ == "__main__":
    main()
