import { describe, expect, it } from "vitest"
import { pluginIconSrc, providerIconSrc } from "./pluginIcon"

describe("pluginIconSrc", () => {
  it("returns the known icon path for a sourced plugin", () => {
    expect(pluginIconSrc("ruby")).toBe("/plugin-icons/ruby.svg")
    expect(pluginIconSrc("syrus-rails")).toBe("/plugin-icons/syrus-rails.svg")
  })

  it("falls back to the SPQR eagle for an unrecognized plugin name", () => {
    expect(pluginIconSrc("some-future-plugin")).toBe("/plugin-icons/spqr_eagle.svg")
  })
})

describe("providerIconSrc", () => {
  it("maps short agent/chat provider ids to their plugin icon", () => {
    expect(providerIconSrc("claude")).toBe("/plugin-icons/claude_agent.svg")
  })

  it("falls back to the SPQR eagle for a provider with no sourced mark", () => {
    expect(providerIconSrc("codex")).toBe("/plugin-icons/spqr_eagle.svg")
  })
})
