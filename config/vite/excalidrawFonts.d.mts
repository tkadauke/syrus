import type { Plugin } from "vite"

export const EXCALIDRAW_PUBLIC_DIR: string
export function excalidrawAssetPath(version: string): string
export function excalidrawFonts(options: { rootDir: string }): Plugin
