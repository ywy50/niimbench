#!/usr/bin/env node
// Reads the trace a live server wrote and insists it says everything a change
// is supposed to say.
//
//   tools/trace-test.js --chrome <browser> --url <url>
//
// This is the harness, and it is the thing to reach for when the editor does
// something wrong: the page records what it did and what it was shown, the
// server records what it was asked, and this reads both. A check that fails
// here fails with the trace in the message, so the next agent starts from the
// record rather than from a screenshot.
//
// The list below is the protocol. A new part of the boot that says nothing, or
// a part that stops saying something, fails this check — so the trace stays
// complete as the page grows instead of drifting behind it.

const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

function parseArgs(argv) {
  const out = { chrome: "", url: "", timeout: 30000 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--chrome") { out.chrome = argv[i + 1]; i += 1; }
    else if (argv[i] === "--url") { out.url = argv[i + 1]; i += 1; }
    else if (argv[i] === "--timeout") { out.timeout = Number(argv[i + 1]); i += 1; }
    else throw new Error("unknown argument: " + argv[i]);
  }
  if (!out.chrome || !out.url) throw new Error("usage: trace-test.js --chrome PATH --url URL");
  return out;
}

const args = parseArgs(process.argv.slice(2));

/// The steps the page says a boot must record, read out of the page itself.
///
/// The list is `tracedSteps` in `src/editor.html`, beside the boot it describes.
/// Keeping it there is the point: a step added to the boot has to be added to
/// the list, and a step in the list with no line in the trace fails. Nothing
/// here can drift behind the page, and no one has to remember a rule.
function requiredSteps(pageHtml) {
  const match = /const tracedSteps = \[([\s\S]*?)\];/.exec(pageHtml);
  if (!match) throw new Error("src/editor.html has no tracedSteps list");
  const steps = match[1]
    .split("\n")
    .map((line) => /"([^"]+)"/.exec(line))
    .filter(Boolean)
    .map((found) => found[1]);
  if (!steps.length) throw new Error("the tracedSteps list in src/editor.html is empty");
  return steps;
}

/// The trace endpoint for the server the page is served from. The URL that the
/// server prints already carries `?token=`, so the path goes before the query
/// rather than after it.
function traceUrl(url) {
  const match = /^(http:\/\/[^/]+\/)\?token=([0-9a-f]+)$/.exec(url);
  if (!match) throw new Error("unexpected server URL: " + url);
  return match[1] + "api/trace?token=" + match[2];
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function getTrace(url) {
  return new Promise((resolve, reject) => {
    const request = require("http").get(traceUrl(url), (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => resolve(body));
    });
    request.on("error", reject);
  });
}

async function main() {
  const pageHtml = fs.readFileSync(path.join(__dirname, "..", "src", "editor.html"), "utf8");
  const dir = fs.mkdtempSync(os.tmpdir() + "/niimbench-trace-");
  // Which browser this is, first: a run that goes wrong on one machine and
  // not another usually differs here.
  const version = spawnSync(args.chrome, ["--version"], { encoding: "utf8", timeout: 20000 });
  console.error("browser: " + args.chrome + " " + String(version.stdout || version.stderr || "").trim());
  // The browser exits when its virtual time is spent, and virtual time stands
  // still while any request is open, so a request that never finishes is a
  // browser that never exits. It is killed after its budget and half a
  // minute, and the trace below then says how far the page got.
  const limit = args.timeout + 30000;
  const run = spawnSync(args.chrome, [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--user-data-dir=" + dir + "/profile",
    "--virtual-time-budget=" + args.timeout,
    "--dump-dom",
    args.url + "#selfcheck",
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: limit, killSignal: "SIGKILL" });
  fs.rmSync(dir, { recursive: true, force: true });
  const timedOut = Boolean(run.error) && run.error.code === "ETIMEDOUT";

  // The page posts its lines as it goes; give the last one a moment to land.
  let trace = "";
  for (let attempt = 0; attempt < 40; attempt++) {
    trace = await getTrace(args.url);
    if (trace.indexOf("checked:") >= 0) break;
    await sleep(250);
  }

  let failures = 0;
  const check = (name, ok, detail) => {
    if (ok) return;
    failures += 1;
    console.error(`  FAIL ${name}${detail ? " \u2014 " + detail : ""}`);
  };

  if (run.error && !timedOut) throw run.error;
  check("the browser finished within its budget", !timedOut,
    `it was still running after ${limit} ms and was killed; the trace below is as far as the page got`);
  if (timedOut || run.status) {
    console.error("--- browser stderr ---");
    console.error(String(run.stderr || "").trim().split("\n").slice(-25).join("\n") || "(none)");
  }
  console.error("--- page errors ---");
  console.error((await getTrace(args.url)).split("\n").filter((line) => line.indexOf("error   page") >= 0).join("\n") || "(none)");
  console.error("--- trace as recorded ---");
  console.error(trace.trimEnd());
  console.error("--- end of trace ---");

  check("the trace is not empty", trace.trim().length > 0);
  // The protocol the run used, as the page reported it. The list is built by
  // tracing, so a run that traced a step is a run whose protocol contains it:
  // requiring the reported list is requiring the run, not the source.
  const protocol = /protocol: ([^\n]*)/.exec(trace);
  if (protocol) {
    const steps = protocol[1].split("|").map((step) => step.trim()).filter(Boolean);
    for (const step of steps) {
      check(`the trace records the step ${JSON.stringify(step)}`, trace.indexOf(step) >= 0,
        "the page put this step in its protocol and the trace has no line for it");
    }
  }
  // The server's own first line. It is the one fact the page cannot report,
  // because the page is not running yet when it is written.
  check("the trace plugin recorded that it opened", /\bopened\b/.test(trace));
  const required = requiredSteps(pageHtml);
  for (const step of required) {
    const present = trace.indexOf(step) >= 0;
    check(`the trace records ${JSON.stringify(step)}`, present,
      "the trace has no such line. " +
      "Either the step did not run, or it ran without saying so: add a traceLine call " +
      "for it in src/editor.html, next to the step. The list it must appear in is " +
      "`tracedSteps` in the same file.");
  }
  // A page that threw says so, and that is worth failing on here rather than
  // leaving to the canvas check.
  check("the page recorded no errors", trace.indexOf("error   page") < 0,
    "the trace has an error from the page");

  if (failures) {
    console.error("The trace above is what the page actually did. Read it before guessing:");
    console.error("  * a missing step is a step that ran without recording itself — add its traceLine;");
    console.error("  * a wrong view, canvas or box in the `view:` and `boxes:` lines is the fault itself;");
    console.error("  * an `error page` line is the page throwing, with the message on it.");
    console.error(`${failures} trace check(s) failed`);
    process.exit(1);
  }
  console.log("trace ok");
}

main().catch((error) => {
  console.error("trace check failed: " + error.message);
  process.exit(1);
});
