import { describe, expect, it } from "vitest"
import { pluginChatMessageComponentFor } from "@app/pluginChatMessageRenderers"
import CoworkerMessage, { withoutMessagePrefix } from "./CoworkerMessage"

describe("Coworkers chat message contribution", () => {
  it("is discovered through the generic plugin renderer registry", () => {
    const component = pluginChatMessageComponentFor("coworkers/CoworkerMessage")

    expect(component).not.toBeNull()
    expect(component).not.toBe(CoworkerMessage)
  })

  it("removes only the matching transport prefix from historical messages", () => {
    expect(withoutMessagePrefix("Message from @maya\n\nHello", "from", "maya")).toBe("Hello")
    expect(withoutMessagePrefix("Message to @maya", "to", "maya")).toBe("")
    expect(withoutMessagePrefix("Unrelated", "from", "maya")).toBe("Unrelated")
  })
})
