#!/usr/bin/env node
// Drive the editor in a headless browser with real input, for a look at the
// page that a self-check does not cover.
//
//   make drive                          open the page, screenshot it, check it ran clean
//   make drive STEPS=my-steps.js        run your own steps against it
//   make drive SIZE=800x900             at another window size
//
// Run it through `make drive` or `tools/with-server.sh node tools/drive.js`,
// which owns the server. It never starts one itself.
//
// A steps file exports one async function, which gets `page`:
//
//   module.exports = async (page) => {
//     const head = await page.center('.panel[data-panel="text"] .panel-head');
//     await page.drag(head, { x: head.x, y: 80 });
//     page.log(await page.evaluate("localStorage.getItem('niimbench.panels')"));
//     await page.shot("moved");
//   };
//
//   page.evaluate(expression)   the value of a JS expression in the page, awaited
//   page.center(selector)       an element's centre in window pixels, scrolled into view
//   page.mouse(type, x, y)      one real mouse event: "move", "down" or "up"
//   page.drag(from, to)         press at `from`, move to `to` in steps, release
//   page.shot(name)             a PNG of the window, saved in DRIVE_OUT; returns its path
//   page.reload()               reload and wait for the page to finish booting
//   page.size(width, height)    resize the window after load, as dragging its edge does
//   page.log(...values)         print a line
//
// The page has booted when a step runs. A step that throws fails the run, and so
// does any error the page itself reports. Screenshots go to DRIVE_OUT
// (default zig-out/drive). BROWSER names the Chromium-family browser.
//
// The browser is started under `setpriv --pdeathsig KILL` when util-linux has
// it, so it dies with this process the way the server dies with with-server.sh.

const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const url = process.env.NIIMBENCH_URL;
const browser = process.env.BROWSER;
const [width, height] = (process.env.SIZE || "1600x1000").split("x").map(Number);
const out = path.resolve(process.env.DRIVE_OUT || path.join(__dirname, "..", "zig-out", "drive"));
const stepsFile = process.argv[2];

if (!url || !process.env.NIIMBENCH_PID) {
  console.error("drive: run me under tools/with-server.sh (make drive does that); it owns the server");
  process.exit(2);
}
if (!browser) {
  console.error("drive: set BROWSER to a Chromium-family browser");
  process.exit(2);
}
if (!width || !height) {
  console.error("drive: SIZE is WIDTHxHEIGHT, for example 1600x1000");
  process.exit(2);
}
const steps = stepsFile ? require(path.resolve(stepsFile)) : async (page) => { await page.shot("opened"); };
if (typeof steps !== "function") {
  console.error("drive: " + stepsFile + " must export one async function");
  process.exit(2);
}

fs.mkdirSync(out, { recursive: true });
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "niimbench-drive-"));
const args = ["--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
  "--disable-background-networking", "--disable-component-update", "--disable-sync", "--disable-default-apps", "--disable-extensions", "--no-first-run", "--no-default-browser-check",
  "--remote-debugging-port=0", "--user-data-dir=" + profile, `--window-size=${width},${height}`, "about:blank"];
const setpriv = ["/usr/bin/setpriv", "/bin/setpriv"].find((file) => fs.existsSync(file));
const child = setpriv
  ? spawn(setpriv, ["--pdeathsig", "KILL", browser, ...args], { stdio: ["ignore", "ignore", "pipe"] })
  : spawn(browser, args, { stdio: ["ignore", "ignore", "pipe"] });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function finish(code) {
  child.kill("SIGKILL");
  fs.rmSync(profile, { recursive: true, force: true });
  process.exit(code);
}

async function main() {
  const endpoint = await new Promise((resolve, reject) => {
    let seen = "";
    const timer = setTimeout(() => reject(new Error("the browser never opened its debugging port: " + seen.slice(0, 300))), 20000);
    child.stderr.on("data", (data) => {
      seen += data;
      const match = /DevTools listening on (ws:\S+)/.exec(seen);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    child.on("exit", (code) => reject(new Error("the browser exited with " + code + ": " + seen.slice(0, 300))));
  });
  const targets = await (await fetch(endpoint.replace("ws://", "http://").replace(/\/devtools\/.*/, "/json"))).json();
  const socket = new WebSocket(targets.find((target) => target.type === "page").webSocketDebuggerUrl);
  await new Promise((resolve) => socket.addEventListener("open", resolve));
  let next = 0;
  const waiting = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id && waiting.has(message.id)) {
      waiting.get(message.id)(message);
      waiting.delete(message.id);
    }
  });
  // A command the browser never answers fails after half a minute, rather
  // than leaving the run waiting on a dead connection.
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    next += 1;
    const id = next;
    const timer = setTimeout(() => { waiting.delete(id); reject(new Error(method + ": no answer in 30 s")); }, 30000);
    waiting.set(id, (message) => {
      clearTimeout(timer);
      if (message.error) reject(new Error(method + ": " + message.error.message));
      else resolve(message.result);
    });
    socket.send(JSON.stringify({ id, method, params }));
  });

  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) {
      throw new Error("in the page: " + (result.exceptionDetails.exception?.description || result.exceptionDetails.text));
    }
    return result.result.value;
  };
  const booted = async () => {
    for (let i = 0; i < 300; i++) {
      try { if (await evaluate("window.__niimbenchChecked === true")) return; } catch (error) { /* still loading */ }
      await sleep(100);
    }
    throw new Error("the page did not finish booting in 30 s");
  };
  const buttons = { move: "mouseMoved", down: "mousePressed", up: "mouseReleased" };
  const mouse = (type, x, y) => {
    if (!buttons[type]) throw new Error("page.mouse type is move, down or up, not " + type);
    return send("Input.dispatchMouseEvent", {
      type: buttons[type], x, y, button: "left", buttons: type === "up" ? 0 : 1, clickCount: 1,
    });
  };
  const page = {
    evaluate,
    mouse,
    async center(selector) {
      const point = await evaluate(`(() => {
        const element = document.querySelector(${JSON.stringify(selector)});
        if (!element) return null;
        element.scrollIntoView({ block: "center" });
        const box = element.getBoundingClientRect();
        return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
      })()`);
      if (!point) throw new Error("no element matches " + selector);
      return point;
    },
    async drag(from, to, steps = 12) {
      await mouse("move", from.x, from.y);
      await mouse("down", from.x, from.y);
      for (let i = 1; i <= steps; i++) {
        await mouse("move", from.x + (to.x - from.x) * i / steps, from.y + (to.y - from.y) * i / steps);
      }
      await mouse("up", to.x, to.y);
    },
    async shot(name) {
      const file = path.join(out, name + ".png");
      const { data } = await send("Page.captureScreenshot", { format: "png" });
      fs.writeFileSync(file, Buffer.from(data, "base64"));
      console.log("drive: screenshot " + file);
      return file;
    },
    async reload() {
      await send("Page.reload");
      await sleep(200);
      await booted();
    },
    async size(w, h) {
      await send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false });
      // Two frames: the resize event, then the layout it causes.
      await evaluate("new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)))");
    },
    log: (...values) => console.log(...values.map((value) => (typeof value === "string" ? value : JSON.stringify(value)))),
  };

  await send("Page.enable");
  await send("Page.navigate", { url });
  await booted();
  await steps(page);
  const errors = await evaluate("window.__niimbenchErrors || []");
  socket.close();
  if (errors.length) {
    console.error("drive: the page reported errors:\n  " + errors.join("\n  "));
    return 1;
  }
  console.log("drive ok (" + width + "x" + height + ")");
  return 0;
}

main().then(finish, (error) => {
  console.error("drive: " + error.message);
  finish(1);
});
