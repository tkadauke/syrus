import { defineConfig } from "vitest/config"
import react from "@vitejs/plugin-react"

// Repo root as a filesystem path (decode %20 etc. — this checkout's path
// contains spaces). No node:path import: the root tsconfig typechecks this
// file without node types.
const rootDir = decodeURIComponent(new URL(".", import.meta.url).pathname)

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "app/assets/builds",
    emptyOutDir: false,
    sourcemap: false,
    rollupOptions: {
      input: "app/frontend/main.tsx",
      output: {
        entryFileNames: "spa.js",
        chunkFileNames: "spa-[name].js",
        assetFileNames: "spa-[name][extname]",
        codeSplitting: false
      }
    }
  },
  test: {
    environment: "jsdom",
    testTimeout: 15000,
    setupFiles: ["app/frontend/test/setup.ts"],
    include: ["app/frontend/**/*.test.{ts,tsx}", "desktop/src/**/*.test.{ts,tsx}"],
    // Desktop component tests would otherwise resolve react from
    // desktop/node_modules while @testing-library/react uses the root copy —
    // two React instances crash every hook. Pin all test imports to one React.
    // @tanstack/react-query and @tanstack/query-core get the same treatment:
    // desktop/node_modules carries a slightly different version that imports
    // its own local react, triggering the same duplicate-React crash.
    alias: {
      react: `${rootDir}node_modules/react`,
      "react-dom": `${rootDir}node_modules/react-dom`,
      "@tanstack/react-query": `${rootDir}node_modules/@tanstack/react-query`,
      "@tanstack/query-core": `${rootDir}node_modules/@tanstack/query-core`
    },
    coverage: {
      provider: "v8",
      reporter: ["lcov"],
      reportsDirectory: "coverage/js",
      include: ["app/frontend/**"],
      exclude: ["app/frontend/**/*.test.*", "app/frontend/**/*.spec.*"]
    }
  }
})
