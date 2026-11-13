import { describe, expect, it } from "vitest"
import { mergeTranscriptDelta, transcriptRefetchInterval } from "./AdminTranscript"
import type { TranscriptPayload } from "../api/adminTranscript"

describe("AdminTranscript polling", () => {
  it("polls active runs and stops after the payload reports completion", () => {
    expect(transcriptRefetchInterval({ finished: false })).toBe(2000)
    expect(transcriptRefetchInterval({ finished: true })).toBe(false)
  })
})

describe("AdminTranscript deltas", () => {
  it("appends newly indexed events without duplicating the existing page", () => {
    const payload = {
      run_id: 1,
      job_id: 2,
      step_kind: "implement",
      workflow_trigger_kind: "initial",
      session_id: "session",
      summary: {
        model: "model",
        total_turns: 1,
        total_tool_calls: 0,
        total_cost_usd: 0,
        exit_reason: null,
        tool_call_counts: {},
        mcp_tool_called: false
      },
      finished: false,
      pagination: { page: 1, per: 100, total_events: 1, total_pages: 1 },
      events: [{ index: 0, kind: "assistant_text", timestamp: null, data: { text: "first" } }]
    } satisfies TranscriptPayload
    const delta = {
      ...payload,
      pagination: { ...payload.pagination, total_events: 2 },
      events: [{ index: 1, kind: "assistant_text", timestamp: null, data: { text: "second" } }]
    }

    expect(mergeTranscriptDelta(payload, delta).events.map((event) => event.index)).toEqual([0, 1])
  })
})
