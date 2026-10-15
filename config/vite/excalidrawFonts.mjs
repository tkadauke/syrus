import { cp, readFile, readdir, rm, stat } from "node:fs/promises"
import { join } from "node:path"

// Excalidraw loads its fonts at runtime from window.EXCALIDRAW_ASSET_PATH and
// otherwise falls back to https://esm.sh, which the content security policy
// (font-src 'self' data:) blocks. Serve them ourselves from public/, outside
// Propshaft, because Excalidraw requests fixed filenames that Propshaft would
// rewrite with a digest. The directory carries the package version so the
// year-long public cache never serves fonts from a previous Excalidraw.
export const EXCALIDRAW_PUBLIC_DIR = "excalidraw-assets"

async function excalidrawVersion(rootDir) {
  const pkg = JSON.parse(await readFile(join(rootDir, "node_modules/@excalidraw/excalidraw/package.json"), "utf8"))
  return pkg.version
}

async function exists(path) {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

export function excalidrawAssetPath(version) {
  return `/${EXCALIDRAW_PUBLIC_DIR}/${version}/`
}

export function excalidrawFonts({ rootDir }) {
  let version

  return {
    name: "syrus-excalidraw-fonts",
    async config() {
      version = await excalidrawVersion(rootDir)
      return { define: { __EXCALIDRAW_ASSET_PATH__: JSON.stringify(excalidrawAssetPath(version)) } }
    },
    async closeBundle() {
      const publicRoot = join(rootDir, "public", EXCALIDRAW_PUBLIC_DIR)
      const target = join(publicRoot, version, "fonts")
      // Watch mode calls this after every rebuild; the fonts only change with
      // the package version.
      if (!(await exists(target))) {
        await cp(join(rootDir, "node_modules/@excalidraw/excalidraw/dist/prod/fonts"), target, { recursive: true })
      }

      for (const entry of await readdir(publicRoot)) {
        if (entry !== version) await rm(join(publicRoot, entry), { recursive: true, force: true })
      }
    }
  }
}
