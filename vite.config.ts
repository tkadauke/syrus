import { defineConfig } from "vitest/config"
import react from "@vitejs/plugin-react"

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
    setupFiles: ["app/frontend/test/setup.ts"],
    include: ["app/frontend/**/*.test.{ts,tsx}", "desktop/src/**/*.test.{ts,tsx}"]
  }
})
