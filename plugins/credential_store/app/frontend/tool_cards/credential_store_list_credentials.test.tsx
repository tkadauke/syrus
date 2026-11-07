import { describe, expect, it } from "vitest"
import toolCard from "./credential_store_list_credentials"

describe("credential_store_list_credentials tool card", () => {
  it("registers a read-only, single-value collapsed summary", () => {
    expect(toolCard.toolName).toBe("credential_store_list_credentials")
    expect(toolCard.readOnly).toBe(true)
    expect(
      toolCard.collapsedSummary?.({
        toolName: toolCard.toolName,
        resultBody: "",
        resultError: false,
        parsedResult: { credentials: [{ id: 1 }, { id: 2 }] }
      })
    ).toBe("2")
  })
})
