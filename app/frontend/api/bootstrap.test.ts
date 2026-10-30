import { afterEach, describe, expect, it, vi } from "vitest"
import { readInitialBootstrap } from "./bootstrap"

describe("readInitialBootstrap", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("returns null after a browser document has been torn down", () => {
    vi.stubGlobal("document", undefined)

    expect(readInitialBootstrap()).toBeNull()
  })
})
