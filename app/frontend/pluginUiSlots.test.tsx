import { describe, expect, it } from "vitest"
import { pluginUiSlotComponentFor, pluginUiSlotComponentKeys } from "./pluginUiSlots"

describe("pluginUiSlots", () => {
  it("returns null for an unknown component key", () => {
    expect(pluginUiSlotComponentFor("nope/Missing")).toBeNull()
    expect(pluginUiSlotComponentFor(null)).toBeNull()
    expect(pluginUiSlotComponentFor(undefined)).toBeNull()
  })

  it("exposes discovered plugin ui_slot component keys as plugin/Component", () => {
    for (const key of pluginUiSlotComponentKeys()) {
      expect(key).toMatch(/^[^/]+\/[^/]+$/)
    }
  })
})
