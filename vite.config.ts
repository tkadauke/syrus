import { loadEnv, type ConfigEnv } from "vite"
import type { ViteUserConfigFnPromise } from "vitest/config"
import react from "@vitejs/plugin-react"
import { excalidrawFonts } from "./config/vite/excalidrawFonts.mjs"

// Repo root as a filesystem path (decode %20 etc. — this checkout's path
// contains spaces). No node:path import: the root tsconfig typechecks this
// file without node types.
const rootDir = decodeURIComponent(new URL(".", import.meta.url).pathname)

const vendorChunkPackages = {
  "vendor-react": ["/react/", "/react-dom/", "/react-router/", "/react-router-dom/"],
  "vendor-query": ["/@tanstack/"],
  "vendor-i18n": ["/i18next/", "/react-i18next/"],
  "vendor-terminal": ["/@xterm/", "/xterm/"],
  "vendor-rails": ["/@rails/"],
  "vendor-ui": ["/@floating-ui/", "/react-joyride/"]
} as const

const lazyVendorPackagePaths = ["/@excalidraw/", "/mermaid/", "/cytoscape", "/d3", "/@shikijs/", "/katex/"] as const

function packageChunkName(normalizedId: string) {
  const modulePath = normalizedId.split("/node_modules/").at(-1)
  if (!modulePath) return undefined

  const segments = modulePath.split("/")
  const packageName = segments[0]?.startsWith("@") ? `${segments[0]}-${segments[1]}` : segments[0]
  return packageName ? `vendor-${packageName.replaceAll(/[^a-zA-Z0-9_-]/g, "-")}` : undefined
}

function manualVendorChunk(id: string) {
  const normalizedId = id.replaceAll("\\", "/")
  // The cross-surface event registry is large and changes independently from
  // most route code, so keep it cacheable outside the startup entry.
  if (normalizedId.endsWith("/app/frontend/lib/appEvents.ts")) return "app-events"
  // Application code, built-in plugin contributions included, is left to the
  // dynamic-import graph. A manual chunk also captures the modules it depends
  // on, so the old "builtin-plugin-contributions" group pulled the whole chat
  // tool-card tree (and React DOM) into a chunk startup had to load.
  if (!normalizedId.includes("/node_modules/")) return undefined
  // Leave route-only packages to Rollup's dynamic-import graph. Assigning a
  // manual chunk here can make a lazy package eager through a shared module
  // (for example Excalidraw's i18n dependency).
  if (lazyVendorPackagePaths.some((packagePath) => normalizedId.includes(packagePath))) return undefined

  for (const [chunkName, packagePaths] of Object.entries(vendorChunkPackages)) {
    if (packagePaths.some((packagePath) => normalizedId.includes(packagePath))) return chunkName
  }

  // Keep unrelated dependencies independently cacheable. A single fallback
  // vendor chunk made a route-only dependency part of every page whenever it
  // shared that chunk with startup code.
  return packageChunkName(normalizedId)
}

const config: ViteUserConfigFnPromise = async ({ mode }: ConfigEnv) => {
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
        input: {
          main: "app/frontend/main.tsx",
          "plugin-host-react": "app/frontend/pluginHost/react.ts",
          "plugin-host-react-jsx-runtime": "app/frontend/pluginHost/reactJsxRuntime.ts",
          "plugin-host-react-dom": "app/frontend/pluginHost/reactDom.ts",
          "plugin-host-react-dom-client": "app/frontend/pluginHost/reactDomClient.ts",
          "plugin-host-react-query": "app/frontend/pluginHost/reactQuery.ts",
          "plugin-host-i18next": "app/frontend/pluginHost/i18next.ts",
          "plugin-host-react-i18next": "app/frontend/pluginHost/reactI18next.ts",
          "plugin-host-sdk": "app/frontend/pluginHost/sdk.ts"
        },
        // External plugin bundles import the named exports of these additional
        // entries at runtime. Keep their public facades even when core itself
        // does not statically consume every export.
        preserveEntrySignatures: "exports-only",
        output: {
          // Propshaft keeps a name as-is only when it ends in
          // `-<hash>.digested.<ext>`; anything else gets a second digest while
          // Vite's import graph still points at the original filename. That
          // includes the entry: lazy chunks import shared code back from it,
          // so it must be served under exactly the name Vite gave it, and the
          // page must load that same URL or the entry runs twice.
          entryFileNames: (chunk) => (chunk.name === "main" ? "spa-entry-[hash].digested.js" : "spa-[name]-[hash].digested.js"),
          chunkFileNames: "spa-[name]-[hash].digested.js",
          assetFileNames: "spa-[name]-[hash].digested[extname]",
          manualChunks: manualVendorChunk
        }
      }
    },
    test: {
      environment: "jsdom",
      // Date and time formatting depends on the host time zone, and a number
      // of suites assert the operator's zone ("EST", "America/New_York").
      // Pin it so the suite gives the same answer everywhere: GitHub's runners
      // are on UTC and failed those suites on every run, while a developer
      // machine on Eastern passed them.
      env: { TZ: "America/New_York" },
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
}

export default config
