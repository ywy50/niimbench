#!/bin/sh
# Lint the editor's page script for names that do not exist.
#
#   tools/lint-page.sh
#
# The page is one inline <script>, so nothing compiles it before a browser
# runs it, and `node --check` only proves it parses. A row handler that reads
# a variable nobody declares, or a call assigned to as if it were a variable,
# parses fine and throws the first time a person uses the control. ESLint's
# `no-undef` finds both without running anything.
set -eu

command -v npx >/dev/null 2>&1 || { echo "lint-page: npx is needed (Node.js)"; exit 1; }
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT INT TERM

node -e '
const fs = require("fs");
const page = fs.readFileSync(process.argv[1], "utf8");
const script = /<script>([\s\S]*)<\/script>/.exec(page);
if (!script) { console.error("lint-page: no <script> in " + process.argv[1]); process.exit(1); }
fs.writeFileSync(process.argv[2], script[1]);
' "$(dirname "$0")/../src/editor.html" "$dir/page.js"

cat > "$dir/eslint.config.mjs" <<'CONFIG'
export default [{
  files: ["page.js"],
  languageOptions: {
    ecmaVersion: 2023,
    sourceType: "script",
    globals: {
      window: "readonly", document: "readonly", location: "readonly", navigator: "readonly",
      localStorage: "readonly", console: "readonly", fetch: "readonly",
      setTimeout: "readonly", clearTimeout: "readonly", requestAnimationFrame: "readonly",
      Event: "readonly", PointerEvent: "readonly", KeyboardEvent: "readonly",
      Image: "readonly", ImageData: "readonly", FileReader: "readonly", Blob: "readonly", URL: "readonly",
      URLSearchParams: "readonly", atob: "readonly", btoa: "readonly", createImageBitmap: "readonly",
      Map: "readonly", Set: "readonly", Promise: "readonly", Uint8Array: "readonly", Uint8ClampedArray: "readonly",
    },
  },
  rules: {
    "no-undef": "error",
    // `harnessChecks` is read out of the page text by tools/canvas.test.js.
    "no-unused-vars": ["error", { args: "none", caughtErrors: "none", varsIgnorePattern: "^harnessChecks$" }],
    "no-unreachable": "error",
    "no-dupe-keys": "error",
    "no-redeclare": "error",
  },
}];
CONFIG

cd "$dir"
npx --yes eslint@9.13.0 page.js
echo "page lint ok"
