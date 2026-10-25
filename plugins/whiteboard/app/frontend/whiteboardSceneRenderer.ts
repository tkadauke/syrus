// Keep Excalidraw's large renderer behind a small lazy-loaded boundary. This
// module also gives tool-card tests a stable seam without loading the full
// browser-only package in jsdom.
export { convertToExcalidrawElements, exportToSvg } from "@excalidraw/excalidraw"
