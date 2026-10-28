#!/usr/bin/env node
// Checks how a picture's tones become dots: the threshold, the five error
// diffusions and the two patterns, and the tone adjustments before them. The
// code lives in the page, so this reads the block between its "picture ink"
// markers out of `src/editor.html` and runs it under node: no browser.
// `make test` runs it as `make dither-test`.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const page = fs.readFileSync(path.join(__dirname, "..", "src", "editor.html"), "utf8");
const start = page.indexOf("    // ---- picture ink ----");
const end = page.indexOf("    // ---- end picture ink ----");
if (start < 0 || end < 0) {
  console.error("the picture ink block was not found in src/editor.html");
  process.exit(1);
}
const block = page.slice(start, end) + "\n;({ pictureDots, inkDefaults, diffusionKernels, orderedMatrices })";
const context = { Math, Float32Array, Uint8Array, Array, Object };
vm.createContext(context);
const { pictureDots, inkDefaults, diffusionKernels, orderedMatrices } = vm.runInContext(block, context);

let failures = 0;
function check(name, ok, detail) {
  if (!ok) {
    failures += 1;
    console.error("FAIL " + name + (detail ? " — " + detail : ""));
  }
}

// A label with a picture painted by `paint(x, y)` -> grey 0..255, or null
// where there is no picture.
function label(width, height, paint) {
  const rgba = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const grey = paint(x, y);
      if (grey === null) continue;
      const i = (y * width + x) * 4;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = grey;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}
const share = (ink, from = 0, to = ink.length) => {
  let dots = 0;
  for (let i = from; i < to; i++) dots += ink[i];
  return Math.round(100 * dots / (to - from));
};
const modes = ["threshold", ...Object.keys(diffusionKernels), ...Object.keys(orderedMatrices)];
const W = 96;
const H = 96;

for (const mode of modes) {
  const settings = { ...inkDefaults, mode };
  // White stays white and black prints solid, whatever the mode.
  check(mode + ": white prints nothing", share(pictureDots(label(W, H, () => 255), W, H, settings)) === 0);
  check(mode + ": black prints solid", share(pictureDots(label(W, H, () => 0), W, H, settings)) === 100);
  // A flat mid-grey: solid by threshold at 160, about half in a dither.
  const grey = share(pictureDots(label(W, H, () => 128), W, H, settings));
  if (mode === "threshold") check("threshold: a grey darker than the cut prints solid", grey === 100, grey + "%");
  else check(mode + ": a mid-grey prints about half its dots", grey >= 45 && grey <= 55, grey + "%");
  // A gradient dark to light: each band prints less than the one before.
  if (mode !== "threshold") {
    const ink = pictureDots(label(W, H, (x) => Math.round(255 * x / (W - 1))), W, H, settings);
    const bands = [];
    for (let b = 0; b < 4; b++) {
      let dots = 0;
      for (let y = 0; y < H; y++) for (let x = b * W / 4; x < (b + 1) * W / 4; x++) dots += ink[y * W + x];
      bands.push(dots);
    }
    check(mode + ": a gradient lightens band by band", bands.every((d, i) => i === 0 || d < bands[i - 1]), bands.join(" > "));
  }
  // Only the picture: a grey square in the middle of a clear label, with
  // brightness all the way down, inks nothing outside the square.
  const square = (x, y) => (x >= 32 && x < 64 && y >= 32 && y < 64 ? 128 : null);
  const ink = pictureDots(label(W, H, square), W, H, { ...settings, brightness: -100 });
  let outside = 0;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (square(x, y) === null) outside += ink[y * W + x];
  check(mode + ": nothing prints outside the picture", outside === 0, outside + " dots");
}

// The adjustments move the share of ink the way they say.
const fs1 = { ...inkDefaults, mode: "floyd-steinberg" };
const at = (settings) => share(pictureDots(label(W, H, () => 128), W, H, settings));
check("brightness up prints less", at({ ...fs1, brightness: 50 }) < at(fs1));
check("brightness down prints more", at({ ...fs1, brightness: -50 }) > at(fs1));
check("gamma above 1 lightens a mid-grey", at({ ...fs1, gamma: 180 }) < at(fs1));
// More contrast pushes a dark grey darker and a light grey lighter.
const of = (grey, settings) => share(pictureDots(label(W, H, () => grey), W, H, settings));
check("contrast up darkens a dark grey", of(90, { ...fs1, contrast: 60 }) > of(90, fs1));
check("contrast up lightens a light grey", of(170, { ...fs1, contrast: 60 }) < of(170, fs1));
// Sharpen makes an edge's dark side darker next to it: the first column in
// from a dark-to-light step inks at least as much.
const step = (settings) => {
  const ink = pictureDots(label(W, H, (x) => (x < W / 2 ? 100 : 160)), W, H, settings);
  let dots = 0;
  for (let y = 0; y < H; y++) dots += ink[y * W + W / 2 - 1];
  return dots;
};
check("sharpen darkens the dark side of an edge", step({ ...fs1, sharpen: 150 }) >= step(fs1), step({ ...fs1, sharpen: 150 }) + " >= " + step(fs1));

if (failures) {
  console.error(failures + " dither check(s) failed");
  process.exit(1);
}
console.log("dither ok (" + modes.length + " modes)");
