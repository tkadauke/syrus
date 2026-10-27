import { describe, expect, it } from "vitest"
import type { TranscriptLog } from "./transcript"
import { transcriptRenderItems } from "./transcriptRenderItems"

function log(overrides: Partial<TranscriptLog> & Pick<TranscriptLog, "id" | "kind" | "chunk">): TranscriptLog {
  return { sequence: overrides.id, created_at: null, ...overrides }
}

describe("transcriptRenderItems", () => {
  it("pairs results by tool_use_id and groups consecutive calls with chat presentation", () => {
    const items = transcriptRenderItems([
      log({ id: 1, kind: "tool_call", chunk: "raw read marker", tool_name: "Read", tool_input: { file_path: "/repo/a.rb" }, tool_use_id: "read-1" }),
      log({ id: 2, kind: "tool_call", chunk: "raw grep marker", tool_name: "Grep", tool_input: { pattern: "needle" }, tool_use_id: "grep-1" }),
      log({ id: 3, kind: "tool_result", chunk: "raw grep result", tool_use_id: "grep-1", tool_result_content: "one match", tool_result_error: false }),
      log({ id: 4, kind: "tool_result", chunk: "raw read result", tool_use_id: "read-1", tool_result_content: "file body", tool_result_error: false }),
      log({ id: 5, kind: "assistant_text", chunk: "Finished." })
    ])

    expect(items).toHaveLength(2)
    expect(items[0]).toMatchObject({
      type: "tool_group",
      tool: "Inspection",
      collapsed_by_default: true,
      outcome_label: "Done",
      calls: [
        { raw_name: "Read", raw_payload: { file_path: "/repo/a.rb" }, result_body: "file body", result_settled: true },
        { raw_name: "Grep", raw_payload: { pattern: "needle" }, result_body: "one match", result_settled: true }
      ]
    })
    expect(items[1]).toMatchObject({ type: "message", role: "assistant", text: "Finished." })
  })

  it("adapts Codex command metadata without displaying raw marker prefixes", () => {
    const [item] = transcriptRenderItems([
      log({
        id: 1,
        kind: "tool_call",
        chunk: "[codex command] /bin/bash -lc 'bundle exec rspec' in_progress",
        tool_name: "bash",
        tool_input: { command: "bundle exec rspec" },
        tool_use_id: "cmd-1"
      }),
      log({
        id: 2,
        kind: "tool_result",
        chunk: "[codex command] /bin/bash -lc 'bundle exec rspec' completed",
        tool_name: "bash",
        tool_use_id: "cmd-1",
        tool_result_content: "2 examples, 0 failures",
        tool_result_error: false
      })
    ])

    expect(item).toMatchObject({
      type: "tool_group",
      summary_label: "bash",
      calls: [{ raw_payload: { command: "bundle exec rspec" }, result_body: "2 examples, 0 failures" }]
    })
    expect(JSON.stringify(item)).not.toContain("[codex command]")
    expect(JSON.stringify(item)).not.toContain("/bin/bash -lc")
  })

  it("adapts Claude content blocks and errors", () => {
    const [item] = transcriptRenderItems([
      log({ id: 1, kind: "tool_call", chunk: "Read(/repo/a.rb)", tool_name: "Read", tool_input: { file_path: "/repo/a.rb" }, tool_use_id: "toolu-1" }),
      log({
        id: 2,
        kind: "tool_result",
        chunk: "permission denied",
        tool_use_id: "toolu-1",
        tool_result_content: [{ type: "text", text: "permission denied" }],
        tool_result_error: true
      })
    ])

    expect(item).toMatchObject({ type: "tool_group", outcome_label: "Failed", calls: [{ result_body: "permission denied", result_error: true }] })
  })

  it("parses legacy flat Codex commands and hides transient file progress", () => {
    const items = transcriptRenderItems([
      log({ id: 1, kind: "tool_call", chunk: "[codex command] bundle exec rspec started" }),
      log({ id: 2, kind: "system", chunk: "[codex file] app/models/job.rb in_progress" }),
      log({ id: 3, kind: "tool_result", chunk: "[codex command] bundle exec rspec completed" }),
      log({ id: 4, kind: "system", chunk: "legacy provider note" })
    ])

    expect(items).toHaveLength(2)
    expect(items[0]).toMatchObject({ type: "tool_group", outcome_label: "Done", calls: [{ raw_payload: { command: "bundle exec rspec" } }] })
    expect(items[1]).toMatchObject({ type: "message", role: "system", text: "legacy provider note" })
  })
})
