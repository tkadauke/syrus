import { describe, expect, it } from "vitest"
import { checkApiVersion, readApiJson } from "../electron/apiVersion"

describe("desktop API version", () => {
  it("accepts the compiled version and unknown fields", async () => {
    await expect(readApiJson<{ value: string }>(new Response(JSON.stringify({ v: 1, value: "ok", future: true })))).resolves.toMatchObject({ value: "ok" })
  })

  it("asks the user to update Syrus Desktop on a mismatch", () => {
    expect(() => checkApiVersion({ v: 2 })).toThrow("update Syrus Desktop")
  })
})
