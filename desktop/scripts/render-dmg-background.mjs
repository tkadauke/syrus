// Renders desktop/build/dmg-background{,@2x}.png and combines them into
// dmg-background.tiff (via `tiffutil -cathidpicheck`). Run whenever the DMG
// art changes:
//
//   npm run ensure:electron && npx electron scripts/render-dmg-background.mjs
//
// The design is the double-click install contract: a single icon slot at the
// contents position from electron-builder.yml, an instruction under it, and
// the Publilius Syrus motto. Keep the geometry in sync with the `dmg:`
// section of electron-builder.yml.
//
// Sizing contract (measured, macOS 26 Finder): dmg-builder ignores the yml
// `window` block when a background image is set and sizes the Finder window
// FRAME from this tiff's 1x pixel size. Finder puts the title bar (~28-33pt
// depending on macOS version) INSIDE that frame, so a canvas that is exactly
// the design height gets its bottom ~33pt clipped — the motto sat right on
// the cut line. The canvas is therefore DESIGN_HEIGHT of art plus
// TITLE_BAR_PAD of plain parchment: the window frame grows by the pad, the
// content area shows the full 400pt design, and on older macOS (shorter
// title bars) the few extra visible rows are seamless parchment margin.
import { app, BrowserWindow } from "electron"
import { execFile } from "node:child_process"
import fs from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)
const buildDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "build")

const WIDTH = 660
// The visible design area. Icon positions in electron-builder.yml and the
// helper-icon rows in scripts/dmg-finder-layout.cjs are expressed against
// this 660x400 canvas.
const DESIGN_HEIGHT = 400
// Extra parchment rows so the Finder window frame (sized from this image)
// has room for its title bar without clipping the design. 33pt measured on
// macOS 26; older Finders use ~28pt and just show a sliver more margin.
const TITLE_BAR_PAD = 33
const HEIGHT = DESIGN_HEIGHT + TITLE_BAR_PAD

// Palette sampled from the brand mark and the original art: parchment field,
// warm slate for the instruction, softer stone for the motto.
const html = `<!doctype html>
<html>
  <body style="margin:0; width:${WIDTH}px; height:${HEIGHT}px; background:#f3e9d0; font-family: Georgia, 'Times New Roman', serif; overflow:hidden;">
    <!-- The app icon (128px, centered at 330,175 by electron-builder.yml)
         sits in the empty area above the instruction. -->
    <div style="position:absolute; left:0; right:0; top:288px; text-align:center; font-size:18px; color:#6b6152;">
      Double-click <span style="color:#b6492e; font-weight:bold;">Syrus</span> to install
    </div>
    <div style="position:absolute; left:0; right:0; top:352px; text-align:center; font-style:italic; font-size:15px; color:#a4977e;">
      Bis dat qui cito dat.
    </div>
  </body>
</html>`

// On a Retina host the offscreen window renders at deviceScaleFactor 2, so a
// single capture of the 660x400 logical page IS the @2x asset; the 1x asset
// is a sips downscale of it.
const capture = async () => {
  const window = new BrowserWindow({
    show: false,
    frame: false,
    width: WIDTH,
    height: HEIGHT,
    useContentSize: true,
    webPreferences: { offscreen: true }
  })

  await window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html)}`)
  // Give layout + font rasterization a beat.
  await new Promise((resolve) => setTimeout(resolve, 500))
  const image = await window.webContents.capturePage()
  window.destroy()
  return image.toPNG()
}

// Without this, Electron's default window-all-closed behavior starts quitting
// the app the moment capture() destroys its offscreen window, abandoning the
// sips/tiffutil steps below mid-flight while still exiting 0.
app.on("window-all-closed", () => {})

app.whenReady().then(async () => {
  try {
    const onex = path.join(buildDir, "dmg-background.png")
    const twox = path.join(buildDir, "dmg-background@2x.png")
    await fs.writeFile(twox, await capture())
    await fs.copyFile(twox, onex)
    await execFileAsync("sips", ["--resampleHeightWidth", String(HEIGHT), String(WIDTH), onex])
    await execFileAsync("tiffutil", [
      "-cathidpicheck",
      onex,
      twox,
      "-out",
      path.join(buildDir, "dmg-background.tiff")
    ])
    console.log(`Rendered DMG background into ${buildDir}`)
    app.exit(0)
  } catch (error) {
    console.error(error)
    app.exit(1)
  }
})
