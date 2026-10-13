#!/usr/bin/env node
// Every relative link in the repository's markdown points at a file that
// exists, and every `#anchor` at a heading in that file.
//
//   node tools/check-doc-links.js
//
// Docs move and headings get renamed; a link that stops resolving is the one
// stale fact nobody re-reads. Anchors use GitHub's rule: the heading lower
// cased, punctuation dropped, spaces turned into hyphens.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.join(__dirname, "..");
const files = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "*.md"], { cwd: root, encoding: "utf8" })
  .split("\n").filter(Boolean)
  // The copied wiki keeps its own links to pages that were not copied.
  .filter((file) => !file.startsWith("docs/manuals/upstream/"));

function slug(heading) {
  return heading.trim().toLowerCase()
    .replace(/[`*_]/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .replace(/\s/g, "-");
}

const anchors = new Map();
function anchorsOf(file) {
  if (anchors.has(file)) return anchors.get(file);
  const set = new Set();
  const seen = new Map();
  let fenced = false;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    if (fenced) continue;
    const heading = /^#{1,6}\s+(.*?)\s*#*\s*$/.exec(line);
    if (!heading) continue;
    const base = slug(heading[1]);
    const count = seen.get(base) || 0;
    seen.set(base, count + 1);
    set.add(count ? `${base}-${count}` : base);
  }
  anchors.set(file, set);
  return set;
}

let failures = 0;
for (const file of files) {
  const text = fs.readFileSync(path.join(root, file), "utf8");
  let fenced = false;
  text.split("\n").forEach((line, index) => {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    if (fenced) return;
    for (const match of line.replace(/`[^`]*`/g, "").matchAll(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
      const target = match[1];
      if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue;
      const [where, anchor] = target.split("#");
      const resolved = where ? path.join(path.dirname(path.join(root, file)), decodeURIComponent(where)) : path.join(root, file);
      const at = `${file}:${index + 1}`;
      if (!fs.existsSync(resolved)) {
        failures += 1;
        console.error(`  FAIL ${at} links to ${target}, which does not exist`);
        continue;
      }
      if (anchor && resolved.endsWith(".md") && !anchorsOf(resolved).has(anchor)) {
        failures += 1;
        console.error(`  FAIL ${at} links to #${anchor}, which is not a heading in ${path.relative(root, resolved)}`);
      }
    }
  });
}

if (failures) {
  console.error(`${failures} broken doc link(s)`);
  process.exit(1);
}
console.log("doc links ok");
