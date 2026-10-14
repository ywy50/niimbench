#!/usr/bin/env node
// Checks the editor's panel board: the rule that moves panels out of each
// other's way when one is dragged or resized.
//
// The promises, from docs/user/guide/index.md:
//
//   1. no two panels overlap, whatever is dragged where;
//   2. no panel is left with a gap above it;
//   3. a dragged panel takes the cell it is dropped on and the others make room;
//   4. a resized panel stays where it is and what it grows into moves below it,
//      unless it narrowed off the panel it rested on, when it floats up;
//   5. the page opens on a layout the rule would not change.
//
// `settlePanels` and the defaults are lifted out of `src/editor.html` and run,
// so this checks the shipped code. `make test` runs it as `make panel-test`.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const page = fs.readFileSync(path.join(__dirname, "..", "src", "editor.html"), "utf8");

function lift(from, to) {
  const start = page.indexOf(from);
  if (start < 0) throw new Error("not found in src/editor.html: " + from);
  const end = page.indexOf(to, start);
  if (end < 0) throw new Error("end not found for: " + from);
  return page.slice(start, end + to.length);
}

const context = {};
vm.createContext(context);
vm.runInContext([
  lift("    const panelColumns = ", ";"),
  lift("    const panelDefaults = {", "\n    };"),
  lift("    function settlePanels(", "\n    }"),
  "this.panelColumns = panelColumns; this.panelDefaults = panelDefaults; this.settlePanels = settlePanels;",
].join("\n"), context);
const { panelColumns, panelDefaults, settlePanels } = context;

let failures = 0;
function check(name, ok, detail) {
  if (ok) return;
  failures += 1;
  console.error(`  FAIL ${name}${detail ? " — " + detail : ""}`);
}

const copy = (layout) => JSON.parse(JSON.stringify(layout));
const overlaps = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
const columnsMeet = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w;

/// The two promises every settled layout keeps, as a reason it does not, or "".
function broken(layout) {
  const ids = Object.keys(layout);
  for (const a of ids) {
    for (const b of ids) {
      if (a < b && overlaps(layout[a], layout[b])) return `${a} overlaps ${b}`;
    }
    const cell = layout[a];
    const resting = cell.y === 0 || ids.some((b) => b !== a && columnsMeet(cell, layout[b]) && layout[b].y + layout[b].h === cell.y);
    if (!resting) return `${a} has a gap above it at row ${cell.y}`;
  }
  return "";
}

// The page opens on the defaults, so they must already be settled.
const opened = settlePanels(copy(panelDefaults));
check("the default layout is settled", JSON.stringify(opened) === JSON.stringify(panelDefaults),
  JSON.stringify(opened));
check("the default layout keeps the promises", broken(opened) === "", broken(opened));
check("the default layout fills the board's width",
  Object.values(panelDefaults).some((cell) => cell.x + cell.w === panelColumns), JSON.stringify(panelDefaults));

// The text panel dragged to the top left takes it, and the preview that was
// there makes room below it.
const top = settlePanels({ ...copy(panelDefaults), text: { ...panelDefaults.text, x: 0, y: 0 } }, "text");
check("a panel dropped on the top left lands there", top.text.x === 0 && top.text.y === 0, JSON.stringify(top.text));
check("the panel it was dropped on moves below it", top.preview.y === top.text.h, JSON.stringify(top.preview));
check("a drop keeps the promises", broken(top) === "", broken(top));

// The preview widened across the board pushes the side column below it.
const wide = settlePanels({ ...copy(panelDefaults), preview: { ...panelDefaults.preview, w: panelColumns } }, "preview", true);
check("a widened panel keeps its place", wide.preview.x === 0 && wide.preview.y === 0, JSON.stringify(wide.preview));
check("a widened panel pushes its neighbour below it", wide.printer.y >= wide.preview.h, JSON.stringify(wide.printer));
check("a resize keeps the promises", broken(wide) === "", broken(wide));

// The text panel widened into the side column, where the printer panel starts
// above it and reaches past its top: the text panel stays under the pointer and
// the printer panel goes below it, rather than the other way round.
const under = settlePanels({ ...copy(panelDefaults), text: { ...panelDefaults.text, w: panelColumns } }, "text", true);
check("a panel resized into a taller neighbour stays where it is",
  under.text.x === panelDefaults.text.x && under.text.y === panelDefaults.text.y, JSON.stringify(under.text));
check("the neighbour it grew into moves below it", under.printer.y === under.text.y + under.text.h, JSON.stringify(under.printer));
check("that resize keeps the promises", broken(under) === "", broken(under));

// A panel dragged down past the top of the one beneath it swaps with it, and
// one dragged less far floats back up.
const stack = { a: { x: 0, y: 0, w: 8, h: 4 }, b: { x: 0, y: 4, w: 8, h: 3 } };
const nudged = settlePanels({ ...copy(stack), a: { ...stack.a, y: 2 } }, "a");
check("a panel moved less than past its neighbour floats back", nudged.a.y === 0 && nudged.b.y === 4, JSON.stringify(nudged));
const swapped = settlePanels({ ...copy(stack), a: { ...stack.a, y: 5 } }, "a");
check("a panel moved past its neighbour's top swaps with it", swapped.b.y === 0 && swapped.a.y === 3, JSON.stringify(swapped));

// Any drop anywhere, from a seeded walk so a failure repeats.
let seed = 7;
const random = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
for (let trial = 0; trial < 2000; trial++) {
  const layout = {};
  for (const id of Object.keys(panelDefaults)) {
    const w = 2 + random(panelColumns - 1);
    layout[id] = { x: random(panelColumns - w + 1), y: random(30), w, h: 2 + random(14) };
  }
  const ids = Object.keys(layout);
  const first = random(2) ? ids[random(ids.length)] : undefined;
  const before = copy(layout);
  const settled = settlePanels(layout, first);
  const why = broken(settled);
  check("a random drop keeps the promises", why === "", why + " in " + JSON.stringify(before) + " first " + first);
  const resized = ids.find((id) => settled[id].x !== before[id].x || settled[id].w !== before[id].w || settled[id].h !== before[id].h);
  check("settling only moves panels up or down", resized === undefined, resized + " in " + JSON.stringify(before));
  if (why || resized) break;

  // Then resize one panel of that settled layout from its corner.
  const id = ids[random(ids.length)];
  const was = { ...settled[id] };
  const grown = copy(settled);
  grown[id].w = 2 + random(panelColumns - was.x - 1);
  grown[id].h = 2 + random(14);
  const after = settlePanels(grown, id, true);
  // Only growing cannot take a panel off what holds it up.
  const grewOnly = grown[id].w >= was.w && grown[id].h >= was.h;
  const stays = after[id].x === was.x && (grewOnly ? after[id].y === was.y : after[id].y <= was.y);
  check("a random resize keeps the promises", broken(after) === "", broken(after) + " resizing " + id + " in " + JSON.stringify(settled));
  check("a resized panel stays where it is, or floats up when it shrank", stays, id + " from " + JSON.stringify(was) + " to " + JSON.stringify(after[id]));
  if (broken(after) || !stays) break;
}

if (failures) {
  console.error(`${failures} panel check(s) failed`);
  process.exit(1);
}
console.log("panel layout ok");
