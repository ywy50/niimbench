#!/usr/bin/env node
// Checks the editor's canvas in a real browser: that the field box is drawn,
// that it is drawn around its own text, and that both are in the view's frame.
//
// `box-geometry.test.js` asserts the page's maths. This asserts the pixels a
// person sees, which is where every one of these bugs actually appeared: a box
// off the canvas, a box beside its text, a box under a view that had been
// turned without it.
//
// The page classifies its own canvas and writes the verdict into the DOM
// (`window.__niimbenchCanvas`), and Chrome is run with `--dump-dom`, so this is
// a plain subprocess that runs to completion. There is no debugging protocol to
// time out and no browser-side promise to await here.
//
//   tools/canvas.test.js --chrome <path> --html <dumped dom file>

const fs = require("fs");
const path = require("path");

function parseArgs(argv) {
  const out = { chrome: "", url: "", timeout: 30000, dump: "" };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    const value = argv[i + 1];
    if (key === "--chrome") { out.chrome = value; i += 1; }
    else if (key === "--url") { out.url = value; i += 1; }
    else if (key === "--dump") { out.dump = value; i += 1; }
    else throw new Error("unknown argument: " + key);
  }
  if (out.dump) return out;
  if (!out.chrome || !out.url) throw new Error("usage: canvas.test.js --chrome PATH --url URL");
  return out;
}

const args = parseArgs(process.argv.slice(2));

let failures = 0;
function check(name, ok, detail) {
  if (ok) return;
  failures += 1;
  console.error(`  FAIL ${name}${detail ? " \u2014 " + detail : ""}`);
}

/// The report the page wrote, from a `--dump-dom` capture.
function reportFromDom(html) {
  const marker = 'id="selftest"';
  const at = html.indexOf(marker);
  if (at < 0) return null;
  const open = html.indexOf(">", at);
  const close = html.indexOf("</div>", open);
  if (open < 0 || close < 0) return null;
  const text = html.slice(open + 1, close)
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&#39;/g, "'");
  try { return JSON.parse(text); } catch (error) { return { error: "unreadable report: " + text.slice(0, 200) }; }
}

function judge(report) {
  if (!report) {
    check("the page wrote a report", false, "no #selftest in the page");
    return;
  }
  if (report.error) {
    check("the page could read its canvas", false, report.error);
    return;
  }
  if (report.errors && report.errors.length) {
    check("the page ran without throwing", false, report.errors.join(" | "));
  }
  check("the canvas is the view's size",
    report.width === report.view.width && report.height === report.view.height,
    `canvas ${report.width}x${report.height}, view ${report.view.width}x${report.view.height}`);
  check("the page drew a field", report.fields > 0, `fields ${report.fields}`);
  check("the page drew the text", Boolean(report.ink) && report.ink.count > 40, JSON.stringify(report.ink));
  check("the page drew a box", Boolean(report.outline),
    "no outline pixels near the ink; colours there: " + JSON.stringify(report.samples) +
    ", overlay " + JSON.stringify(report.overlay) + ", quad " + JSON.stringify(report.quad) +
    ", clipped " + JSON.stringify(report.clipped) + ", stroke " + JSON.stringify(report.colors) +
    ", rects " + JSON.stringify(report.rects) + ", field " + JSON.stringify(report.field) +
    ", debug " + JSON.stringify(report.debug));
  if (!report.ink || !report.outline) return;

  const ink = report.ink;
  const box = report.outline;
  // The box is drawn around its text: it holds the ink, and it is not simply
  // the whole canvas, which would hold any ink at all.
  check("the box is drawn around its text",
    box.minX <= ink.minX + 1 && box.maxX >= ink.maxX - 1 &&
    box.minY <= ink.minY + 1 && box.maxY >= ink.maxY - 1,
    `ink x ${ink.minX}..${ink.maxX} y ${ink.minY}..${ink.maxY}, box x ${box.minX}..${box.maxX} y ${box.minY}..${box.maxY}`);
  const box_w = box.maxX - box.minX + 1;
  const box_h = box.maxY - box.minY + 1;
  check("the box is not the whole canvas",
    box_w < report.width - 2 && box_h < report.height - 2,
    `${box_w}x${box_h} on ${report.width}x${report.height}`);
  check("the box is on the canvas",
    box.minX >= 0 && box.minY >= 0 && box.maxX < report.width && box.maxY < report.height,
    `box x ${box.minX}..${box.maxX} y ${box.minY}..${box.maxY} in ${report.width}x${report.height}`);
  // The box is around the text rather than beside it: their centres agree.
  const ink_cx = (ink.minX + ink.maxX) / 2;
  const box_cx = (box.minX + box.maxX) / 2;
  const ink_cy = (ink.minY + ink.maxY) / 2;
  const box_cy = (box.minY + box.maxY) / 2;
  check("the box is centred on its text",
    Math.abs(ink_cx - box_cx) <= 3 && Math.abs(ink_cy - box_cy) <= 6,
    `ink centre ${ink_cx},${ink_cy} box centre ${box_cx},${box_cy}`);
  // And the anchor is on the text's top side, which is where it is drawn.
  const overlay = report.overlay;
  check("the anchor is above the box", overlay && overlay.minY < box.minY - 4,
    `outline y ${box.minY}..${box.maxY}, overlay y ${overlay && overlay.minY}..${overlay && overlay.maxY}`);

  // The drag the page ran on itself. A box that jumps is a box whose step does
  // not match the pointer's, and the page counts both.
  check("the page exercised a drag", Boolean(report.drag) && report.drag.moves > 0,
    JSON.stringify(report.drag));
  if (report.drag && report.drag.moves > 0) {
    check("the box kept step with the pointer while dragging", report.drag.ok === true,
      JSON.stringify(report.drag));
  }
  // The corner resize the page ran on itself: the text grew, and the corner
  // opposite the one dragged stayed where it was.
  check("dragging a corner resized the text and pinned the opposite corner",
    Boolean(report.resize) && report.resize.ok === true, JSON.stringify(report.resize));
  // Typing into a row, and picking its size and font, reach the field. A row
  // whose handler throws leaves the field as it was.
  check("editing a row's text, size and font changes its field",
    Boolean(report.edit) && report.edit.ok === true, JSON.stringify(report.edit));
  // Every font the renderer carries is offered in the row's font menu.
  check("a row offers every font the server carries",
    Boolean(report.fonts) && report.fonts.served > 1 && report.fonts.offered === report.fonts.served,
    JSON.stringify(report.fonts));

  // The row's controls, as the browser laid them out. Two controls sharing
  // pixels is a broken row, and the numbers say so without anyone having to see
  // it in a picture: this is the check for four buttons that overlapped inside a
  // 67-pixel column.
  const row = report.row;
  check("the page laid out a field row", Boolean(row) && row.children.length > 0, JSON.stringify(row));
  if (row && row.children.length) {
    const shown = row.children.filter((child) => child.width > 0);
    let overlap = null;
    for (const first of shown) {
      for (const second of shown) {
        if (first === second) continue;
        // Only controls on the same line can be in each other's way: a row that
        // wraps is doing the right thing.
        if (Math.abs((first.top || 0) - (second.top || 0)) > 2) continue;
        if (second.left > first.left && second.left < first.left + first.width - 1) {
          overlap = `${first.tag}.${first.cls} at ${first.left}+${first.width} and ` +
            `${second.tag}.${second.cls} at ${second.left} (line ${first.top})`;
        }
      }
    }
    check("no two controls in a row overlap", overlap === null,
      `${overlap}; row width ${row.width}, children ` +
      JSON.stringify(shown.map((c) => [c.tag + "." + c.cls, c.left, c.width])));

    const outside = shown.filter((child) => child.left < -1 || child.left + child.width > row.width + 1);
    check("every control is inside its row", outside.length === 0,
      JSON.stringify(outside.map((c) => [c.tag + "." + c.cls, c.left, c.width])) + " in " + row.width);

    const actions = shown.find((child) => child.cls.indexOf("actions") >= 0);
    check("the row's buttons have room", Boolean(actions) && actions.width >= 150, JSON.stringify(actions));
  }
}

function describe(report) {
  if (!process.env.CANVAS_VERBOSE && !failures) return;
  console.error("canvas report: " + JSON.stringify(report, null, 1));
  if (!report || !report.row) return;
  console.error("row width " + report.row.width);
  for (const child of report.row.children) {
    console.error("  " + child.tag + "." + child.cls + " left " + child.left +
      " width " + child.width + " value " + JSON.stringify(child.value));
  }
}

/// The page declares what its self-check reports in `harnessChecks`, and every
/// one of those facts must be asserted here. The page is where a new fact is
/// introduced and this is where it must be watched; failing here is what keeps
/// the harness in step with the page instead of behind it.
function checkHarnessCoversThePage() {
  const page = fs.readFileSync(path.join(__dirname, "..", "src", "editor.html"), "utf8");
  const list = /const harnessChecks = \[([^\]]*)\]/.exec(page);
  check("the page declares what the harness must check", Boolean(list),
    "no harnessChecks list in src/editor.html");
  if (!list) return;
  const names = list[1].split(",").map((part) => part.trim().replace(/["']/g, "")).filter(Boolean);
  check("the declared check list is not empty", names.length > 0);
  const self = fs.readFileSync(__filename, "utf8");
  for (const name of names) {
    check(`the harness checks ${JSON.stringify(name)}`, self.indexOf("report." + name) >= 0,
      `the self-check reports ${name} and nothing here reads report.${name}. ` +
      "Add a check to tools/canvas.test.js, or drop it from harnessChecks in src/editor.html.");
  }
}

if (args.dump) {
  checkHarnessCoversThePage();
  const report = reportFromDom(fs.readFileSync(args.dump, "utf8"));
  judge(report);
  describe(report);
} else {
  const { spawnSync } = require("child_process");
  const os = require("os");
  const dir = fs.mkdtempSync(os.tmpdir() + "/niimbench-canvas-");
  const dump = dir + "/dom.html";
  const run = spawnSync(args.chrome, [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--user-data-dir=" + dir + "/profile",
    "--virtual-time-budget=" + args.timeout,
    "--dump-dom",
    args.url + "#selfcheck",
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (run.error) throw run.error;
  if (run.status !== 0) {
    console.error("chrome exited with " + run.status + ": " + String(run.stderr).slice(0, 400));
  }
  fs.writeFileSync(dump, run.stdout || "");
  const report = reportFromDom(run.stdout || "");
  judge(report);
  describe(report);
  fs.rmSync(dir, { recursive: true, force: true });
}

if (failures) {
  console.error(`${failures} canvas check(s) failed`);
  process.exit(1);
}
console.log("canvas ok");
