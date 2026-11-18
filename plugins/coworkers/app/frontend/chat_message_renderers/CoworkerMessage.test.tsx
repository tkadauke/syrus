import { describe, expect, it } from "vitest"
import { pluginChatMessageComponentFor } from "@app/pluginChatMessageRenderers"
import CoworkerMessage, { withoutMessagePrefix } from "./CoworkerMessage"
import deCoworkers from "../i18n/locales/de/coworkers.json"
import enCoworkers from "../i18n/locales/en/coworkers.json"
import laCoworkers from "../i18n/locales/la/coworkers.json"

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

  it("localizes the working-session link in every supported locale", () => {
    expect(enCoworkers.chat.view_working_session).toBe("View working session")
    expect(deCoworkers.chat.view_working_session).toBe("Arbeitssitzung anzeigen")
    expect(laCoworkers.chat.view_working_session).toBe("Sessionem operis vide")
  })
})
