import { loadEnv } from "vite"
import { defineConfig } from "vitest/config"
import react from "@vitejs/plugin-react"
import { excalidrawFonts } from "./config/vite/excalidrawFonts.mjs"

// Repo root as a filesystem path (decode %20 etc. — this checkout's path
// contains spaces). No node:path import: the root tsconfig typechecks this
// file without node types.
const rootDir = decodeURIComponent(new URL(".", import.meta.url).pathname)

const vendorChunkPackages = {
  "vendor-react": ["/react/", "/react-dom/", "/react-router/", "/react-router-dom/"],
  "vendor-query": ["/@tanstack/"],
  "vendor-excalidraw": ["/@excalidraw/"],
  "vendor-diagrams": ["/mermaid/", "/cytoscape/"],
  "vendor-d3": ["/d3"],
  "vendor-editor": ["/@shikijs/", "/katex/"],
  "vendor-terminal": ["/@xterm/", "/xterm/"],
  "vendor-i18n": ["/i18next/", "/react-i18next/"],
  "vendor-rails": ["/@rails/"],
  "vendor-ui": ["/@floating-ui/", "/react-joyride/"]
} as const

function packageChunkName(normalizedId: string) {
  const modulePath = normalizedId.split("/node_modules/").at(-1)
  if (!modulePath) return undefined

  const segments = modulePath.split("/")
  const packageName = segments[0]?.startsWith("@") ? `${segments[0]}-${segments[1]}` : segments[0]
  return packageName ? `vendor-${packageName.replaceAll(/[^a-zA-Z0-9_-]/g, "-")}` : undefined
}

function manualVendorChunk(id: string) {
  const normalizedId = id.replaceAll("\\", "/")
  if (!normalizedId.includes("/node_modules/")) return undefined

  for (const [chunkName, packagePaths] of Object.entries(vendorChunkPackages)) {
    if (packagePaths.some((packagePath) => normalizedId.includes(packagePath))) return chunkName
  }

  // Keep unrelated dependencies independently cacheable. A single fallback
  // vendor chunk made a route-only dependency part of every page whenever it
  // shared that chunk with startup code.
  return packageChunkName(normalizedId)
}

export default defineConfig(async ({ mode }) => {
  const env = loadEnv(mode, rootDir, "")
  const buildSourcemap = env.VITE_BUILD_SOURCEMAP === "true"
  const analyzeBundle = env.VITE_BUNDLE_ANALYZE === "true"
  const analysisPlugin = analyzeBundle
    ? (await import("rollup-plugin-visualizer")).visualizer({
        filename: "docs/bundle-analysis.html",
        gzipSize: true,
        brotliSize: true,
        template: "treemap"
      })
    : false

  return {
    // Rails serves the production bundle through Propshaft's /assets mount.
    // Vite uses this base for CSS and module dependencies preloaded by lazy
    // imports, while static chunk imports remain relative to their importer.
    base: "/assets/",
    plugins: [react(), excalidrawFonts({ rootDir }), analysisPlugin],
    resolve: {
      alias: {
        "@app": `${rootDir}app/frontend`,
        "@plugins": `${rootDir}plugins`
      }
    },
    build: {
      outDir: "app/assets/builds",
      emptyOutDir: false,
      sourcemap: buildSourcemap,
      // The entry is content-hashed like every chunk, so the layout learns its
      // current name from .vite/manifest.json (Syrus::ViteEntrypoint).
      manifest: true,
      rollupOptions: {
        input: "app/frontend/main.tsx",
        output: {
          // Propshaft keeps a name as-is only when it ends in
          // `-<hash>.digested.<ext>`; anything else gets a second digest while
          // Vite's import graph still points at the original filename. That
          // includes the entry: lazy chunks import shared code back from it,
          // so it must be served under exactly the name Vite gave it, and the
          // page must load that same URL or the entry runs twice.
          entryFileNames: "spa-entry-[hash].digested.js",
          chunkFileNames: "spa-[name]-[hash].digested.js",
          assetFileNames: "spa-[name]-[hash].digested[extname]",
          manualChunks: manualVendorChunk
        }
      }
    },
    test: {
      environment: "jsdom",
      testTimeout: 15000,
      maxWorkers: 4,
      setupFiles: ["app/frontend/test/setup.ts"],
      include: [
        "app/frontend/**/*.test.{ts,tsx}",
        "plugins/*/app/frontend/**/*.test.{ts,tsx}",
        "desktop/src/**/*.test.{ts,tsx}",
        "eslint-rules/**/*.test.js",
        // Other website tests use Node's built-in runner via test:locales;
        // Vitest cannot bundle their node:test imports into jsdom.
        "website/lib/plugins.test.ts"
      ],
      // Desktop component tests would otherwise resolve react from
      // desktop/node_modules while @testing-library/react uses the root copy —
      // two React instances crash every hook. Pin all test imports to one React.
      // @tanstack/react-query and @tanstack/query-core get the same treatment:
      // desktop/node_modules carries a slightly different version that imports
      // its own local react, triggering the same duplicate-React crash.
      alias: {
        electron: `${rootDir}desktop/src/test/electron.ts`,
        react: `${rootDir}node_modules/react`,
        "react/jsx-runtime": `${rootDir}node_modules/react/jsx-runtime.js`,
        "react/jsx-dev-runtime": `${rootDir}node_modules/react/jsx-dev-runtime.js`,
        "react-dom": `${rootDir}node_modules/react-dom`,
        "@app": `${rootDir}app/frontend`,
        "@plugins": `${rootDir}plugins`,
        "@tanstack/react-query": `${rootDir}node_modules/@tanstack/react-query`,
        "@tanstack/query-core": `${rootDir}node_modules/@tanstack/query-core`
      },
      coverage: {
        provider: "v8",
        reporter: ["lcov"],
        reportsDirectory: "coverage/js",
        include: ["app/frontend/**/*.{ts,tsx}"],
        exclude: ["app/frontend/**/*.test.*", "app/frontend/**/*.spec.*"]
      }
    }
  }
})
