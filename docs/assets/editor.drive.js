// The README's screenshot, docs/assets/editor.png: the editor on a 50×30 mm
// B21 label with three fields. Refresh it after the page changes with:
//
//   make drive STEPS=docs/assets/editor.drive.js SIZE=1440x900 DRIVE_OUT=docs/assets
const layout = {
  width: 384,
  height: 240,
  model: "b21",
  label: "50x30",
  density: 5,
  rotate: 0,
  conn: "usb",
  addr: "",
  fields: [
    { text: "niimbench", x: 192, y: 44, size: 64, font: "dejavu-sans-bold", align_mode: "center", rotation: 0 },
    { text: "label bench for Niimbot", x: 192, y: 124, size: 26, font: "open-sans", align_mode: "center", rotation: 0 },
    { text: "B21 · 50×30 mm · 203 dpi", x: 192, y: 176, size: 20, font: "dejavu-sans-mono", align_mode: "center", rotation: 0 },
  ],
};

module.exports = async (page) => {
  await page.evaluate(`(async () => { applyLayout(${JSON.stringify(layout)}); await refresh(); })()`);
  // No scrollbar down the edge of a picture.
  await page.evaluate("window.scrollTo(0, 0); document.documentElement.style.overflow = 'hidden'");
  await page.shot("editor");
};
