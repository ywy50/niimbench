#!/usr/bin/env node
// Checks the trace protocol in the page's own source, without a browser and
// without a server.
//
//   node tools/trace-protocol.test.js
//
// The protocol is the steps a boot must record. `tracedSteps` in
// `src/editor.html` starts with the steps the server writes, and `traceStep`
// adds every step the page records as it runs. This check ties both to the
// code, so they cannot drift:
//
//   * every step listed in the page's source must be written somewhere — by a
//     `traceStep` or `traceLine` call in the page, or by the server's trace —
//     so a step cannot be listed but never recorded;
//   * each boot phase must record a step near it, so a phase cannot be added
//     that says nothing.
//
// `make test` runs it as `make protocol-test`. `make trace-test` is the fuller
// check: it runs the page and reads the trace back.

const fs = require("fs");
const path = require("path");

const page = fs.readFileSync(path.join(__dirname, "..", "src", "editor.html"), "utf8");
// The steps the server writes itself, before the page exists.
const server = fs.readFileSync(path.join(__dirname, "..", "src", "trace.zig"), "utf8");

let failures = 0;
const check = (name, ok, detail) => {
  if (ok) return;
  failures += 1;
  console.error(`  FAIL ${name}${detail ? " \u2014 " + detail : ""}`);
};

// The protocol, read from the page.
const list = /const tracedSteps = \[([\s\S]*?)\];/.exec(page);
check("src/editor.html declares tracedSteps", Boolean(list),
  "the trace protocol list is missing; tools/trace-test.js reads it too");
const steps = list
  ? list[1].split("\n").map((line) => /"([^"]+)"/.exec(line)).filter(Boolean).map((found) => found[1])
  : [];
check("the declared step list is not empty", steps.length > 0);

// Every traceLine call, with its literal prefix where it has one, and every
// traceStep call, which records at info.
const calls = [
  ...[...page.matchAll(/traceLine\(\s*"([a-z]+)"\s*,\s*"([^"]*)"/g)]
    .map((match) => ({ level: match[1], text: match[2] })),
  ...[...page.matchAll(/traceStep\(\s*"([^"]*)"/g)].map((match) => ({ level: "info", text: match[1] })),
];

check("the page records something", calls.length > 0);

for (const step of steps) {
  const has = calls.some((call) => call.text.startsWith(step)) || server.includes(`"${step}"`);
  check(`a step is declared and recorded: ${JSON.stringify(step)}`, has,
    "the step is in tracedSteps but neither the page nor src/trace.zig records it. " +
    "Add the line next to the step, or drop the step from the list.");
}

// A line whose text begins with a declared step must be recorded at info, so a
// warning cannot stand in for a completed step.
for (const call of calls) {
  const declared = steps.some((step) => call.text.startsWith(step));
  if (!declared) continue;
  check(`a recorded step is at info: ${JSON.stringify(call.text.slice(0, 40))}`, call.level === "info",
    `recorded at ${call.level}`);
}

// Every phase of the boot has to say what it is doing. Counted, so a phase that
// grows a branch still has to record something for it.
const phases = [
  { name: "the boot asks for the label sizes", needle: "api(\"/api/label/sizes\")" },
  { name: "the boot asks for the metrics", needle: "api(\"/api/label/metrics\")" },
  // The scan records what it found inside the function the boot calls.
  { name: "the boot scans for a printer", needle: "async function scanDevices(" },
  // The boot's own placement starts once the startup scan has settled.
  { name: "the boot places its first field", needle: "      .then(() => scanDevices(false, true))\n      .catch(() => {})\n" },
];
const starts = phases.map((phase) => page.indexOf(phase.needle));
for (const [i, phase] of phases.entries()) {
  const at = starts[i];
  check(`the page still has the phase: ${phase.name}`, at >= 0, "not found in the page");
  if (at < 0) continue;
  // A step inside the phase: from its own code to where the next phase
  // starts, so a neighbour's step cannot stand in for it.
  const later = starts.filter((start) => start > at);
  const end = Math.min(later.length ? Math.min(...later) : Infinity, at + 1500);
  const around = page.slice(at, end);
  check(`the phase says what it is doing: ${phase.name}`,
    around.includes("traceStep(") || around.includes("traceLine(\"info\""),
    "no traceStep(...) or traceLine(\"info\", ...) near this phase");
}

if (failures) {
  console.error(`${failures} trace protocol check(s) failed`);
  process.exit(1);
}
console.log("trace protocol ok");
