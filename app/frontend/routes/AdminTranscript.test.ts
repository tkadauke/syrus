import { describe, expect, it } from "vitest"
import { advanceTranscriptCursor, mergeTranscriptDelta, transcriptRefetchInterval } from "./AdminTranscript"
import type { TranscriptPayload } from "../api/adminTranscript"

describe("AdminTranscript polling", () => {
  it("polls active runs and stops after the payload reports completion", () => {
    expect(transcriptRefetchInterval({ finished: false })).toBe(2000)
    expect(transcriptRefetchInterval({ finished: true })).toBe(false)
  })
})

describe("AdminTranscript deltas", () => {
  it("starts live polling after the transcript total instead of the displayed page", () => {
    const payload = transcriptPayload({
      pagination: { page: 1, per: 100, total_events: 1000, total_pages: 10 },
      events: [{ index: 99, kind: "assistant_text", timestamp: null, data: { text: "page end" } }]
    })

    expect(advanceTranscriptCursor(undefined, payload)).toBe(1000)
  })

  it("advances through a bounded delta without skipping the rest of a burst", () => {
    const delta = transcriptPayload({
      pagination: { page: 1, per: 100, total_events: 1200, total_pages: 12 },
      events: [{ index: 1099, kind: "assistant_text", timestamp: null, data: { text: "delta end" } }]
    })

    expect(advanceTranscriptCursor(1000, delta)).toBe(1100)
  })

  it("appends newly indexed events without duplicating the existing page", () => {
    const payload = transcriptPayload()
    const delta = {
      ...payload,
      pagination: { ...payload.pagination, total_events: 2 },
      events: [{ index: 1, kind: "assistant_text", timestamp: null, data: { text: "second" } }]
    }

    expect(mergeTranscriptDelta(payload, delta).events.map((event) => event.index)).toEqual([0, 1])
  })
})

function transcriptPayload(overrides: Partial<TranscriptPayload> = {}) {
  return {
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
    events: [{ index: 0, kind: "assistant_text", timestamp: null, data: { text: "first" } }],
    ...overrides
  } satisfies TranscriptPayload
}
