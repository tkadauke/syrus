declare global {
  interface Window {
    EXCALIDRAW_ASSET_PATH?: string | string[]
  }
}

// Excalidraw resolves its font URLs against this when it loads a font. Left
// unset, it falls back to a public CDN the content security policy blocks.
// The build copies the fonts here (config/vite/excalidrawFonts.mjs).
export function configureExcalidrawAssets() {
  window.EXCALIDRAW_ASSET_PATH = __EXCALIDRAW_ASSET_PATH__
}
