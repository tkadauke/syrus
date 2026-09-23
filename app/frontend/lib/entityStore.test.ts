import { afterEach, describe, expect, it } from "vitest"
import { entityHasFields, normalizeChatPayload, normalizeJobDetailPayload, readEntity, resetEntityStoreForTest, upsertEntity } from "./entityStore"
import type { ChatPayload } from "../api/chats"
import type { JobDetailPayload } from "../api/jobs"

describe("entityStore", () => {
  afterEach(() => resetEntityStoreForTest())

  it("merges partial and full snapshots without erasing known fields", () => {
    upsertEntity({
      kind: "jobs",
      id: 42,
      fields: { id: 42, issue_title: "Keep me", state: "open", updated_at: "2026-09-01T00:00:00Z" },
      completeness: "summary",
      source: "test"
    })

    upsertEntity({
      kind: "jobs",
      id: 42,
      fields: { id: 42, state: "running", issue_body: "New detail", updated_at: "2026-09-01T00:01:00Z" },
      completeness: "detail",
      source: "test"
    })

    const record = readEntity("jobs", 42)
    expect(record?.fields.issue_title).toBe("Keep me")
    expect(record?.fields.state).toBe("running")
    expect(record?.fields.issue_body).toBe("New detail")
    expect(record?.completeness).toBe("detail")
    expect(entityHasFields("jobs", 42, ["issue_title", "issue_body"], "detail")).toBe(true)
  })

  it("ignores older revisions for the same entity", () => {
    upsertEntity({
      kind: "jobs",
      id: 42,
      fields: { id: 42, state: "running", updated_at: "2026-09-02T00:00:00Z" },
      source: "new"
    })

    upsertEntity({
      kind: "jobs",
      id: 42,
      fields: { id: 42, state: "queued", updated_at: "2026-09-01T00:00:00Z" },
      source: "old"
    })

    expect(readEntity("jobs", 42)?.fields.state).toBe("running")
  })

  it("normalizes job detail snapshots into canonical entity records", () => {
    normalizeJobDetailPayload({
      job: { id: 42, state: "open", issue_title: "Normalize me", updated_at: "2026-09-01T00:00:00Z" },
      repository: { id: 7, slug: "acme/widgets", owner: "acme", name: "widgets", default_branch: "main" },
      epic: { id: 9, number: 12, display_number: "EPIC-12", title: "Stateful UI", state: "open", epic_path: "/epics/9" },
      workflows: [
        {
          id: 100,
          state: "running",
          updated_at: "2026-09-01T00:00:00Z",
          steps: [
            { id: 200, state: "running", updated_at: "2026-09-01T00:00:00Z", runs: [{ id: 300, state: "running", updated_at: "2026-09-01T00:00:00Z" }] }
          ]
        }
      ]
    } as unknown as JobDetailPayload)

    expect(readEntity("jobs", 42)?.fields.issue_title).toBe("Normalize me")
    expect(readEntity("repositories", 7)?.fields.slug).toBe("acme/widgets")
    expect(readEntity("epics", 9)?.fields.title).toBe("Stateful UI")
    expect(readEntity("workflows", 100)?.fields.state).toBe("running")
    expect(readEntity("steps", 200)?.fields.state).toBe("running")
    expect(readEntity("runs", 300)?.fields.state).toBe("running")
  })

  it("normalizes chat sessions, messages, repositories, and materialized jobs", () => {
    normalizeChatPayload({
      chat: {
        id: 5,
        title: "Origin chat",
        title_pending: false,
        pinned: false,
        pinned_context: null,
        chat_path: "/chats/5",
        repository: { id: 7, slug: "acme/widgets" },
        stop_requested_at: null,
        cumulative_input_tokens: 0,
        cumulative_output_tokens: 0,
        cumulative_cost_usd: 0
      },
      recent_chats: [],
      messages: [
        {
          type: "message",
          id: 10,
          role: "assistant",
          text: "Created a job",
          bookmarkable: true,
          proposal: {
            materialized: { kind: "job", job_id: 42, job_title: "Fix it", job_state: "open" }
          }
        }
      ]
    } as unknown as ChatPayload)

    expect(readEntity("chat_sessions", 5)?.fields.title).toBe("Origin chat")
    expect(readEntity("chat_messages", 10)?.fields.text).toBe("Created a job")
    expect(readEntity("repositories", 7)?.fields.slug).toBe("acme/widgets")
    expect(readEntity("jobs", 42)?.fields.issue_title).toBe("Fix it")
  })
})
