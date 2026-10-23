import fs from "node:fs"
import path from "node:path"
import { describe, expect, it } from "vitest"

const source = (relativePath: string) => fs.readFileSync(path.resolve(process.cwd(), relativePath), "utf8")

describe("desktop shell localization coverage", () => {
  it("keeps native dialog copy out of Electron main", () => {
    const main = source("electron/main.ts")
    for (const literal of [
      'message: "Update the Syrus backend?"',
      'message: "Set up Syrus again?"',
      'message: "Your local Syrus data is gone."',
      'message: "Stop Syrus?"',
      'message: "Finishing backend update…"',
      'title: "Reset Test Setup"'
    ]) {
      expect(main).not.toContain(literal)
    }
  })

  it("keeps reviewed renderer-shell copy behind catalog calls", () => {
    const app = source("src/App.tsx")
    for (const literal of [
      ">Notifications<",
      ">Mark all read<",
      'title="Loading inbox"',
      'placeholder="What should be changed?"',
      'aria-label="Compose direct job"',
      ">Checkout locally<"
    ]) {
      expect(app).not.toContain(literal)
    }
  })
})
