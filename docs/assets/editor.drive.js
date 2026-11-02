// The README's screenshot, docs/assets/editor.png: the editor with a D110_M
// connected. The startup scan picks it, its 12x40 roll is read, and one field
// is set to "niimbench", turned to the Vertical view and fitted to the label.
// docs/assets/README.md has the command that takes it.
const wait = (expr, ms) => `new Promise((resolve) => {
  const started = Date.now();
  (function poll() { if ((${expr}) || Date.now() - started > ${ms}) resolve(); else setTimeout(poll, 250); })();
})`;

module.exports = async (page) => {
  await page.evaluate(wait(`!document.querySelector("#printer-roll").hidden`, 40000));
  await page.evaluate(`(async () => {
    const row = rows[0];
    row.controls.font.value = "dejavu-sans-bold";
    row.controls.font.dispatchEvent(new Event("change", { bubbles: true }));
    row.controls.text.value = "niimbench";
    row.controls.text.dispatchEvent(new Event("input", { bubbles: true }));
    document.querySelector("#upright").checked = true;
    document.querySelector('.orient button[data-rotate="90"]').click();
    await refresh();
    [...row.row.querySelectorAll("button")].find((b) => b.textContent === "Fit").click();
    await refresh();
    document.activeElement && document.activeElement.blur();
  })()`);
  // The printer's address, and the serial in its name, belong to the printer
  // the shot was taken with: the picture shows the README's example address
  // and the bare model. The roll is not read again, so nothing reads that
  // address before the shot.
  await page.evaluate(`(() => {
    rollWatch = false;
    const mac = document.querySelector("#addr").value;
    document.querySelector("#addr").value = "AA:BB:CC:DD:EE:FF";
    const walker = document.createTreeWalker(document.querySelector("#device"), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      node.textContent = node.textContent.replace(mac, "AA:BB:CC:DD:EE:FF").replace(/^([A-Z0-9_]+)-[A-Z0-9]+$/, "$1");
    }
  })()`);
  await page.evaluate("window.scrollTo(0, 0); document.documentElement.style.overflow = 'hidden'");
  await page.shot("editor");
};
