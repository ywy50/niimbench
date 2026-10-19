// Steps for tools/drive.js: the page at the screen sizes people use, from a
// phone to a wide desktop, each reached by resizing the window after load.
//
//   make screens-test
//
// At every size nothing may stick out of the page or the text panel, and no
// two controls in a text row may overlap. The check exists because the page was
// only ever looked at one size: on a phone the board's 24 columns and their
// gaps alone were wider than the screen, and between 52rem and 60rem every row
// was forced 40rem wide and cut off its buttons. Those pass a single-size check.
const sizes = [
  [360, 780], [390, 844], [768, 1024], [900, 1000], [1024, 768],
  [1280, 800], [1440, 900], [1920, 1080], [2560, 1440],
  // Wide, then narrow again: the layout must not depend on the way there.
  [1920, 1080], [1024, 768],
];

const measure = `(() => {
  const problems = [];
  const doc = document.documentElement;
  if (doc.scrollWidth > doc.clientWidth + 1) problems.push("the page scrolls sideways: " + doc.scrollWidth + " > " + doc.clientWidth);
  const body = document.querySelector('.panel[data-panel="text"] .panel-body');
  if (body.scrollWidth > body.clientWidth + 1) problems.push("the text panel scrolls sideways: " + body.scrollWidth + " > " + body.clientWidth);
  const name = (e) => (e.textContent || e.tagName).trim().slice(0, 12);
  // The panel's visible box, not only the row's: a row wider than its panel,
  // scrolled inside the list, still cuts off whatever is past the edge.
  const view = body.getBoundingClientRect();
  for (const row of document.querySelectorAll("#field-list .field")) {
    const edge = row.getBoundingClientRect();
    const controls = [...row.querySelectorAll("textarea, select, input, button")]
      .map((e) => [e, e.getBoundingClientRect()]).filter(([, b]) => b.width > 0);
    for (const [e, b] of controls) {
      if (b.left < edge.left - 1 || b.right > edge.right + 1) problems.push(name(e) + " sticks out of its row");
      if (b.left < view.left - 1 || b.right > view.right + 1) problems.push(name(e) + " is cut off by the panel");
    }
    for (const [a, ab] of controls) for (const [b, bb] of controls) {
      if (a !== b && ab.left < bb.right - 1 && bb.left < ab.right - 1 && ab.top < bb.bottom - 1 && bb.top < ab.bottom - 1) {
        problems.push(name(a) + " overlaps " + name(b));
      }
    }
  }
  return [...new Set(problems)];
})()`;

module.exports = async (page) => {
  // A long line, and a text box dragged far wider than any row: the box stops
  // at the row's edge instead of widening the panel.
  await page.evaluate(`(() => {
    document.querySelector("#add-field").click();
    const boxes = document.querySelectorAll("#field-list textarea");
    const box = boxes[boxes.length - 1];
    box.value = "A rather long line of label text, longer than the box";
    box.dispatchEvent(new Event("input"));
    box.style.width = "5000px";
  })()`);
  let failed = [];
  const check = async (what) => {
    const problems = await page.evaluate(measure);
    page.log(what + (problems.length ? ": " + problems.join("; ") : " ok"));
    failed = failed.concat(problems.map((problem) => what + ": " + problem));
  };
  for (const [width, height] of sizes) {
    await page.size(width, height);
    await check(width + "x" + height);
  }
  // A text panel dragged narrow on the board, a third of the window, is as
  // narrow as a phone's while the window is not.
  for (const [width, height] of [[900, 1000], [1440, 900]]) {
    await page.size(width, height);
    await page.evaluate(`document.querySelector('.panel[data-panel="text"]').style.setProperty("--col", "1 / span 8")`);
    await check(width + "x" + height + " with a narrow text panel");
  }
  if (failed.length) throw new Error("the page does not fit:\n  " + failed.join("\n  "));
};
