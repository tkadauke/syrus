import { describe, expect, it } from "vitest"
import toolCard, { examples } from "./credential_store_list_credentials"

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

  it("provides a catalog fixture with multiple scopes and long metadata", () => {
    expect(examples).toHaveLength(1)
    expect(examples[0]).toMatchObject({
      id: "multiple_scopes_with_long_metadata",
      parsedResult: {
        count: 3,
        credentials: [
          { scope: "repository", safe_metadata: expect.any(Object), target_constraints: expect.any(Object) },
          { scope: "team", safe_metadata: expect.any(Object), target_constraints: expect.any(Object) },
          { scope: "instance", safe_metadata: expect.any(Object), target_constraints: expect.any(Object) }
        ]
      }
    })
  })
})
