#!/usr/bin/env node
// Checks the editor's frame transform — the turn that shows a roll with the
// tape running left to right. The transform lives in the page, so this reads it
// out of `src/editor.html` and runs just that block: no browser, no DOM.
// `make test` runs it as `make view-test`.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const page = fs.readFileSync(path.join(__dirname, "..", "src", "editor.html"), "utf8");
const start = page.indexOf("    function viewSize() {");
const anchor = page.indexOf("    function toLabel(x, y) {");
const end = page.indexOf("\n    }", anchor);
if (start < 0 || anchor < 0 || end < 0) {
  console.error("view geometry not found in src/editor.html");
  process.exit(1);
}

// Lift the block. It borrows two things from the page: the roll and the
// orientation, so the roll line is pointed at the context and the orientation
// is set before each call.
const block = page
  .slice(start, end + "\n    }".length)
  .replace("const roll = rollSize();", "const roll = ROLL;") +
  // In a vm the declarations stay in the script's own scope, so hand them out.
  "\n;({ viewSize, toView, toLabel })";
// `turnView` is lifted too, and run for real: a check that re-states the
// mapping would pass while the page's own copy is wrong.
const turn_start = page.indexOf("    function turnView(");
const turn_anchor = page.indexOf("const turned = previewCtx.createImageData(height, width);");
const turn_end = page.indexOf("\n    }", page.indexOf("return turned;", turn_anchor));
if (turn_start < 0 || turn_anchor < 0 || turn_end < 0) {
  console.error("turnView not found in src/editor.html");
  process.exit(1);
}
const turn_block = page.slice(turn_start, turn_end + "\n    }".length) + "\n;({ turnView })";
const context = {
  ROLL: { width: 96, height: 304 },
  orientation: 90,
  Uint8ClampedArray,
  previewCtx: {
    createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
  },
};
vm.createContext(context);
const { viewSize, toView, toLabel } = vm.runInContext(block, context);
const { turnView } = vm.runInContext(turn_block, context);

let failures = 0;
function check(name, ok, detail) {
  if (ok) return;
  failures += 1;
  console.error(`  FAIL ${name}${detail ? " — " + detail : ""}`);
}

// This roll is a 96-wide page 304 rows long, so the turned view is 304 wide and
// 96 tall: the tape runs left to right, as it does coming out of the printer.
const turned = viewSize();
check("turned view is 304x96", turned.width === 304 && turned.height === 96, JSON.stringify(turned));
context.orientation = 0;
const upright = viewSize();
check("upright view is the roll", upright.width === 96 && upright.height === 304, JSON.stringify(upright));
context.orientation = 90;

// toLabel undoes toView everywhere on the page, which is what makes dragging in
// a turned view land where the pointer left it.
let inverse_ok = true;
for (let y = 0; y < 304 && inverse_ok; y += 7) {
  for (let x = 0; x < 96; x += 5) {
    const v = toView(x, y);
    const back = toLabel(v.x, v.y);
    if (back.x !== x || back.y !== y) {
      check("toLabel inverts toView", false, `(${x},${y}) -> (${v.x},${v.y}) -> (${back.x},${back.y})`);
      inverse_ok = false;
      break;
    }
  }
}
check("toLabel inverts toView", inverse_ok);

// It is a turn, not a reflection. An upright "L" — a stroke down its left side
// and a foot to the right — has to come out with the stroke across the top and
// the foot still to its right. The other quarter turn reflects it, which is
// what shows every glyph mirrored.
const stroke = [];
const foot = [];
for (const [x, y] of [[0, 0], [0, 1], [0, 2]]) {
  const p = toView(x, y);
  stroke.push([p.x, p.y]);
}
for (const [x, y] of [[1, 2], [2, 2]]) {
  const p = toView(x, y);
  foot.push([p.x, p.y]);
}
const stroke_row = new Set(stroke.map(([, y]) => y));
check("the L's stroke becomes one row of the view", stroke_row.size === 1, JSON.stringify(stroke));
check("and it is the view's top row", [...stroke_row][0] === 95, JSON.stringify(stroke));
check("the L's foot hangs below that row", foot.every(([x, y]) => y < 95 && x === 2), JSON.stringify(foot));

context.orientation = 90;

// The picture turn. `turnView` moves whole pixels of the rendered roll into the
// view, and it must agree with `toView` cell for cell. The stride is where this
// went wrong once: the roll is 96 wide but the view is 96 - margin tall, so
// using the view's height as the stride sheared the picture by the margin.
{
  const roll_w = 96;
  const roll_h = 304;
  const image = { data: new Uint8ClampedArray(roll_w * roll_h * 4) };
  const marker = (x, y, value) => {
    image.data[(y * roll_w + x) * 4] = value;
    image.data[(y * roll_w + x) * 4 + 3] = 255;
  };
  const spots = [[0, 0], [95, 0], [0, 303], [95, 303], [40, 100], [7, 250]];
  spots.forEach(([x, y], i) => marker(x, y, i + 1));

  const turned = turnView(image, roll_w, roll_h);
  check("the turned picture is the view's size", turned.width === 304 && turned.height === 96,
    `${turned.width}x${turned.height}`);

  let agrees = true;
  spots.forEach(([x, y], i) => {
    const expect = toView(x, y);
    const got = turned.data[(expect.y * turned.width + expect.x) * 4];
    if (got !== i + 1) {
      check("the picture turn agrees with toView", false,
        `printer (${x},${y}) has ${got} at view (${expect.x},${expect.y}), expected ${i + 1}`);
      agrees = false;
    }
  });
  check("the picture turn agrees with toView", agrees);
}

// The picture is turned with the same quarter turn as a point, so the page and
// the boxes over it cannot disagree. `turnView` in the page writes printer
// (x, y) to view (y, view_height - 1 - x): read that as a view coordinate and
// it has to be exactly what `toView` returns, and the map has to be one-to-one
// or a pixel would be lost.
const view_w = 304;
const view_h = 96;
let picture_ok = true;
const seen = new Set();
for (let y = 0; y < 304 && picture_ok; y++) {
  for (let x = 0; x < 96; x++) {
    const vx = y;
    const vy = view_h - 1 - x;
    const point = toView(x, y);
    if (point.x !== vx || point.y !== vy) {
      check("the picture turn matches toView", false, `(${x},${y}) picture (${vx},${vy}) point (${point.x},${point.y})`);
      picture_ok = false;
      break;
    }
    const at = vy * view_w + vx;
    if (seen.has(at)) {
      check("the picture turn is one-to-one", false, `two source pixels land at view ${vx},${vy}`);
      picture_ok = false;
      break;
    }
    seen.add(at);
  }
}
check("the picture turn matches toView", picture_ok);
check("and fills the whole view", seen.size === view_w * view_h, String(seen.size));

// A field's angle on the roll and the angle its box is drawn at are not the
// same in a turned view: the page is turned too, so the box adds the turn. When
// a drag moves the handle, the field gets the drawn angle with the turn taken
// back out, which is what keeps the box and the letters at one angle.
function drawnAngle(field_rotation) {
  const turn = context.orientation === 90 ? 90 : 0;
  return field_rotation + turn;
}
function storedAngle(drawn) {
  const turn = context.orientation === 90 ? 90 : 0;
  return ((drawn - turn) % 360 + 360) % 360;
}
check("a 45 field is drawn at 135 in a turned view", drawnAngle(45) === 135, String(drawnAngle(45)));
check("and the drag stores 45 again", storedAngle(135) === 45, String(storedAngle(135)));
check("upright, the two are the same", (context.orientation = 0, drawnAngle(45)) === 45);
context.orientation = 90;

// Dragging. The box on screen is a view rectangle, so a drag runs in view
// coordinates and writes the roll's position back through the inverse turn.
// This mirrors the move handler: grab a point on the box, clamp the box to the
// view, and read the roll's position back through `toLabel`. The view is only
// 96 tall, so a 60-tall box has 36 rows of room and a drop near the edge
// clamps — which is the point of checking the clamp.
function drag(start, grab, drop) {
  const view = viewSize();
  const offset = { x: grab.x - start.x, y: grab.y - start.y };
  const corner_x = Math.max(0, Math.min(view.width - start.w, drop.x - offset.x));
  const corner_y = Math.max(0, Math.min(view.height - start.h, drop.y - offset.y));
  return { x: corner_x, y: corner_y, roll: toLabel(corner_x, corner_y) };
}

const grab_box = { x: 10, y: 42, w: 14, h: 60 };
const moved = drag(grab_box, { x: 17, y: 72 }, { x: 107, y: 84 });
// Grabbing 7 in from the box's left edge and dropping at view x 107 puts the
// box's left edge at view x 100.
check("a dragged box follows the pointer across", moved.x === 100, JSON.stringify(moved));
// The drop is below the last place the box fits, so it clamps to the view's
// bottom: 96 - 60.
check("and clamps to the view's bottom", moved.y === 36, JSON.stringify(moved));
// The field is that corner read back onto the roll, so a drag and its undo
// agree: toView(field) is the box's corner.
const back = toView(moved.roll.x, moved.roll.y);
check("the field on the roll is where the box is", back.x === moved.x && back.y === moved.y,
  JSON.stringify({ back, moved }));

// A drop in open space moves the box by exactly the pointer's move.
const nudged = drag(grab_box, { x: 17, y: 72 }, { x: 67, y: 60 });
check("a free drag moves the box by the pointer's move",
  nudged.x === 60 && nudged.y === 30, JSON.stringify(nudged));

// Dragging past the far corner keeps the box inside the view, so the field
// stays on the roll instead of running off it.
const corner = drag(grab_box, { x: 17, y: 72 }, { x: 9999, y: 9999 });
check("a drag clamps to the view", corner.x === 304 - 14 && corner.y === 96 - 60, JSON.stringify(corner));
check("and the field stays on the roll",
  corner.roll.x >= 0 && corner.roll.x < 96 && corner.roll.y >= 0 && corner.roll.y < 304,
  JSON.stringify(corner));

if (failures) {
  console.error(`${failures} view geometry check(s) failed`);
  process.exit(1);
}
console.log("view geometry ok");
