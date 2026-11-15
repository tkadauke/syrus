import { describe, expect, it } from "vitest"
import { jobDetailPayloadPaths, mergeJobDetailPayload } from "../electron/jobDetailPayload"

describe("desktop job detail payload", () => {
  it("loads the lean header and summary tab endpoints", () => {
    expect(jobDetailPayloadPaths(42)).toEqual(["/api/v1/app/jobs/42", "/api/v1/app/jobs/42/tabs/summary"])
  })

  it("merges summary, test plan, and feedback into the lean header", () => {
    const header = { job: { id: 42 }, repository: { slug: "acme/widgets" } }
    const summary = { summary: { text: "Done" }, test_plan: { steps: ["Verify"] }, feedback_history: [{ body: "Fix this" }] }
    expect(mergeJobDetailPayload(header, summary)).toEqual({ ...header, ...summary })
  })
})
