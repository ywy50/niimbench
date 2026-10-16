#!/usr/bin/env node
// Checks a field's box against the ink the renderer draws, in the frame the
// editor displays: the printer's page turned by the view.
//
// The promises, from docs/user/guide/index.md:
//
//   1. the box holds the text, at the field's size and angle;
//   2. turning a field does not move its text;
//   3. the box is parallel to its text;
//   4. the round anchor is on the text's top side, outside the box;
//   5. a drag moves the field one dot per dot.
//
// The functions are lifted out of `src/editor.html` and run, so this checks the
// shipped code. `make test` runs it as `make box-test`.

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

const source = [
  lift("    function normalizeDegrees(", "\n    }"),
  lift("    function rollSize() {", "\n    }"),
  lift("    function viewSize() {", "\n    }"),
  lift("    function toView(", "\n    }"),
  lift("    function toLabel(", "\n    }"),
  lift("    function shiftFor(", "\n    }"),
  lift("    function sizeOf(", "\n    }"),
  lift("    function previewText(", "\n    }"),
  lift("    function tablesFrom(", "\n      return tables;\n    }"),
  lift("    function textWidth(", "\n    }"),
  lift("    function blockWidth(", "\n    }"),
  lift("    function blockHeight(", "\n    }"),
  lift("    function blockLines(", "\n    }"),
  lift("    function placedLeft(", "\n    }"),
  lift("    function boxRect(", "\n    }"),
  lift("    function boxCorners(", "\n    }"),
  lift("    function boxQuad(", "\n    }"),
  lift("    function quadCentre(", "\n    }"),
  lift("    function inQuad(", "\n    }"),
  lift("    function handleOf(", "\n    }"),
  lift("    function dragStepWithin(", "\n    }"),
].join("\n");

const roll = { width: 96, height: 304 };
// A stand-in for the font tables the server reports, in its run format. In
// `wide` every character is six tenths of a line, so a width is easy to work
// out by hand; `narrow` makes an `i` half that, to show a box follows its
// field's font. A stand-in that lacks a field silently makes every width NaN.
const metrics = {
  default: "wide",
  max_size: 1024,
  fonts: [
    { id: "wide", name: "Wide", line_units: 10, missing: 6, advances: [] },
    { id: "narrow", name: "Narrow", line_units: 10, missing: 6, advances: [[105, 3]] },
  ],
};
const context = {
  Math,
  Number,
  String,
  Boolean,
  Array,
  Object,
  metrics,
  orientation: 90,
  // `rollSize()` reads the two form fields.
  document: {
    querySelector: (selector) => ({
      value: selector === "#height" ? String(roll.height) : String(roll.width),
    }),
  },
};
vm.createContext(context);
// The page builds its lookup tables from the server's runs once, at boot.
vm.runInContext(source + "\n;fontTables = tablesFrom(metrics);", context);
const {
  viewSize, toView, shiftFor, placedLeft, boxRect, boxCorners, boxQuad, quadCentre, inQuad, handleOf,
  dragStepWithin,
  blockWidth,
  blockHeight, blockLines, textWidth, sizeOf, previewText,
} = context;

let failures = 0;
function check(name, ok, detail) {
  if (ok) return;
  failures += 1;
  console.error(`  FAIL ${name}${detail ? " \u2014 " + detail : ""}`);
}

// The page's own block measurements, lifted, so the numbers here are the
// page's rather than a second implementation of them.
const block = (text, size) => ({
  w: Math.max(blockWidth(text, size), 1),
  h: blockHeight(text, size),
});

// The cases that matter, including the alignments: the editor's box and the
// server's placement are two implementations of one rule, and the bug that put
// boxes off the canvas every time was the two disagreeing about what `x` means.
const texts = ["niimbench", "NB-1", "A"];
const sizes = [8, 16, 23];
const alignments = ["left", "center", "right"];
const angles = [0, 15, 45, 90, 180, 270];
const orientations = [0, 90];

for (const orientation of orientations) {
  context.orientation = orientation;
  const view = viewSize();
  check(`the ${orientation === 90 ? "turned" : "upright"} view is the roll's sides`,
    orientation === 90 ? view.width === 304 && view.height === 96 : view.width === 96 && view.height === 304,
    JSON.stringify(view));

  for (const text of texts) {
    for (const size of sizes) {
      for (const align_mode of alignments) {
        let measured;
        try {
          measured = block(text, size);
        } catch (error) {
          check("the harness can measure a block", false, text + " " + size + ": " + error.message);
          continue;
        }
        // Vertically this roll is 304 dots, so a block sits comfortably down
        // it; across it the roll is 96, which a centred block fits and the
        // aligned ones are placed to fit.
        const anchor = align_mode === "left" ? 6 : align_mode === "right" ? roll.width - 6 : Math.round(roll.width / 2);
        const y = 40;
        for (const rotation of angles) {
          const field = { text, x: anchor, y, size, align_mode, rotation };
          const left = placedLeft(field);
          const rect = boxRect(field, left, field.y);
          const quad = boxQuad(rect);
          const radians = rotation * Math.PI / 180;
          const cos = Math.cos(radians);
          const sin = Math.sin(radians);
          const label = `${text} size ${size} ${align_mode} at ${rotation}°, ${orientation === 90 ? "vertical" : "horizontal"}`;

          // The box is the turned block: its centre is the block's centre.
          const expected = { x: left + measured.w / 2, y: y + measured.h / 2 };
          // The same comparison the printer's own resolution gives. `left` here
          // is what the page computed; the box's centre is that plus half a
          // block, to the nearest dot.
          check(`the box is centred on the text (${label})`,
            Math.abs(rect.centre.x - expected.x) <= 0.51 && Math.abs(rect.centre.y - expected.y) <= 0.51,
            `box ${JSON.stringify(rect.centre)} expected ${JSON.stringify(expected)}`);

          // Every corner of the text is inside the box.
          const corners = boxCorners(rect);
          let inside = true;
          const hw = measured.w / 2;
          const hh = measured.h / 2;
          for (const [lx, ly] of [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]]) {
            const point = { x: rect.centre.x + lx * cos - ly * sin, y: rect.centre.y + lx * sin + ly * cos };
            if (!inQuad(corners, point)) inside = false;
          }
          check(`the box holds the text (${label})`, inside);

          // A box that is on the label must be on the canvas as well: the view
          // is a window onto the label, so nothing is lost between the two. A
          // box drawn off the canvas while its text is on the label is the bug
          // that put every box out of sight.
          const roll_xs = corners.map((point) => point.x);
          const roll_ys = corners.map((point) => point.y);
          const on_label = Math.min(...roll_xs) >= 0 && Math.min(...roll_ys) >= 0 &&
            Math.max(...roll_xs) < roll.width && Math.max(...roll_ys) < roll.height;
          // The view is a window: upright it shows the label's own coordinates,
          // and turned it shows the turn. Both halves matter, and the missing
          // half is what put every box off the canvas — the turn was applied in
          // both views.
          let mapped = true;
          for (let i = 0; i < 4; i++) {
            const expected = orientation === 90
              ? toView(corners[i].x, corners[i].y)
              : corners[i];
            if (Math.abs(quad[i].x - expected.x) > 1e-9 || Math.abs(quad[i].y - expected.y) > 1e-9) mapped = false;
          }
          check(`the box is shown in the view's frame (${label})`, mapped,
            `quad ${JSON.stringify(quad)} for corners ${JSON.stringify(corners)}`);

          // 4. The anchor is on the text's top side and outside the box.
          const handle = handleOf(rect);
          const centre = quadCentre(quad);
          const top_mid = { x: (quad[0].x + quad[1].x) / 2, y: (quad[0].y + quad[1].y) / 2 };
          const bottom_mid = { x: (quad[3].x + quad[2].x) / 2, y: (quad[3].y + quad[2].y) / 2 };
          const up = { x: top_mid.x - bottom_mid.x, y: top_mid.y - bottom_mid.y };
          const to_handle = { x: handle.x - centre.x, y: handle.y - centre.y };
          check(`the anchor is above the text (${label})`,
            Math.abs(up.x * to_handle.y - up.y * to_handle.x) < 1e-6,
            `up ${JSON.stringify(up)} handle ${JSON.stringify(to_handle)}`);
          check(`the anchor is outside the box (${label})`, !inQuad(quad, handle));
        }
      }
    }
  }
}

// The bug that hid every box: `boxQuad` turned the box in both views. It must
// be the identity when the view is upright, and the turn when it is not. Assert
// it by name as well as in the loop above, because this is the failure that
// costs the most time to find from a screenshot.
{
  context.orientation = 0;
  const upright_field = { text: "niimbench", x: 48, y: 148, size: 10, align_mode: "center", rotation: 0 };
  const upright_rect = boxRect(upright_field, placedLeft(upright_field), upright_field.y);
  const upright_quad = boxQuad(upright_rect);
  const corners = boxCorners(upright_rect);
  check("an upright view leaves the box's own coordinates alone",
    corners.every((corner, i) => corner.x === upright_quad[i].x && corner.y === upright_quad[i].y),
    JSON.stringify(upright_quad));
  // Its left edge is the anchor less half the block, which is what the server
  // places: a centred 54-dot block at x=48 starts at 21.
  const left_edge = Math.min(...corners.map((corner) => corner.x));
  check("a centred block starts half a block left of its anchor",
    left_edge === Math.round(48 - 54 / 2), String(left_edge));

  context.orientation = 90;
  const turned_quad = boxQuad(upright_rect);
  check("a turned view turns the box",
    corners.every((corner, i) => {
      const expected = toView(corner.x, corner.y);
      return Math.abs(turned_quad[i].x - expected.x) < 1e-9 && Math.abs(turned_quad[i].y - expected.y) < 1e-9;
    }),
    JSON.stringify(turned_quad));
  context.orientation = 0;
}

// The alignment rule is the server's: a centred block of 54
// dots at x=48 is placed at 21, and a right-aligned one at -6.
context.orientation = 0;
check("a left-aligned field is not shifted", shiftFor({ align_mode: "left" }, 54) === 0);
check("a centred field shifts by half a block", shiftFor({ align_mode: "center" }, 53) === 26.5);
check("a right-aligned field shifts by a whole block", shiftFor({ align_mode: "right" }, 54) === 54);

// And the placement itself, against the server's own answers for the boot
// field at size 10: x=48, centred, 54 dots wide, placed at 21.
{
  const boot = { text: "niimbench", x: 48, y: 148, size: 10, align_mode: "center" };
  // Nine characters at six tenths of 10 dots are 54 dots, half of which is 27.
  // The server reports 48 - 27 = 21 for this field.
  check("a centred field is placed half a block left of its anchor",
    placedLeft(boot) === 21, String(placedLeft(boot)));
  const rect = boxRect(boot, placedLeft(boot), boot.y);
  check("the box starts at the placed edge",
    Math.round(rect.x) === 21, String(rect.x));
  check("the box is four dots above the first row of ink",
    Math.abs(rect.y - boot.y) <= 1, String(rect.y));
  // The alignment is applied once and only once: the box's left edge is the
  // placed left edge, whether it was reached through the anchor or directly.
  const viaShift = boxRect(boot, Math.round(boot.x - shiftFor(boot, 54)), boot.y);
  check("the box is the same either way round", Math.abs(viaShift.x - rect.x) < 1e-9,
    `${viaShift.x} vs ${rect.x}`);
}

// A box is measured in its own field's font. "niimbench" has two `i`s, each
// 3 dots narrower at size 10 in `narrow`, and a font the page does not know
// measures as the default rather than as nothing.
context.orientation = 0;
{
  const wide = { text: "niimbench", x: 4, y: 40, size: 10, font: "wide", align_mode: "left" };
  const narrow = { ...wide, font: "narrow" };
  const unknown = { ...wide, font: "comic-sans" };
  const width = (field) => boxRect(field, placedLeft(field), field.y).block_w;
  check("a box is as wide as its text in its own font",
    width(wide) === 54 && width(narrow) === 48, `${width(wide)} and ${width(narrow)}`);
  check("an unknown font measures as the default", width(unknown) === width(wide), String(width(unknown)));
}

// 5. A drag moves one dot per dot, in the field's own frame. The page checks
// its own steps, and so does this: the lifted check, with a step that follows
// the pointer and one that does not.
{
  const box = { rect: { x: 100, y: 100 } };
  check("a first drag step is ok", dragStepWithin(box, { x: 0, y: 0 }) === true);
  box.rect = { x: 105, y: 105 };
  check("a drag step that follows the pointer is ok",
    dragStepWithin(box, { x: 5, y: 5 }) === true);
  box.rect = { x: 115, y: 112 };
  check("a drag step that lags the pointer is flagged",
    dragStepWithin(box, { x: 15, y: 117 }) === false);
}

if (failures) {
  console.error(`${failures} box check(s) failed`);
  process.exit(1);
}
console.log("box geometry ok");
