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
  "vendor-visualization": ["/d3", "/mermaid/", "/cytoscape"]
} as const

function manualVendorChunk(id: string) {
  const normalizedId = id.replaceAll("\\", "/")
  if (!normalizedId.includes("/node_modules/")) return undefined

  for (const [chunkName, packagePaths] of Object.entries(vendorChunkPackages)) {
    if (packagePaths.some((packagePath) => normalizedId.includes(packagePath))) return chunkName
  }

  return "vendor"
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, rootDir, "")
  const buildSourcemap = env.VITE_BUILD_SOURCEMAP !== "false"

  return {
    // Rails serves the production bundle through Propshaft's /assets mount.
    // Vite uses this base for CSS and module dependencies preloaded by lazy
    // imports, while static chunk imports remain relative to their importer.
    base: "/assets/",
    plugins: [react(), excalidrawFonts({ rootDir })],
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
      include: ["app/frontend/**/*.test.{ts,tsx}", "plugins/*/app/frontend/**/*.test.{ts,tsx}", "desktop/src/**/*.test.{ts,tsx}", "eslint-rules/**/*.test.js"],
      // Desktop component tests would otherwise resolve react from
      // desktop/node_modules while @testing-library/react uses the root copy —
      // two React instances crash every hook. Pin all test imports to one React.
      // @tanstack/react-query and @tanstack/query-core get the same treatment:
      // desktop/node_modules carries a slightly different version that imports
      // its own local react, triggering the same duplicate-React crash.
      alias: {
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
