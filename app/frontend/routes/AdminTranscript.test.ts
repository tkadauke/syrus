import { describe, expect, it } from "vitest"
import { transcriptRefetchInterval } from "./AdminTranscript"

describe("AdminTranscript polling", () => {
  it("polls active runs and stops after the payload reports completion", () => {
    expect(transcriptRefetchInterval({ finished: false })).toBe(2000)
    expect(transcriptRefetchInterval({ finished: true })).toBe(false)
  })
})
