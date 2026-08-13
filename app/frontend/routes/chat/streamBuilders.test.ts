import { describe, expect, it } from "vitest"
import type { ChatPendingAction } from "../../api/chats"
import { pendingActionCardData } from "./streamBuilders"

describe("pendingActionCardData", () => {
  it("carries the resource title and url through to the inline card", () => {
    const action: ChatPendingAction = {
      id: 501,
      label: "Add dark mode toggle",
      detail: "**Branch:** syrus/chat-42-handoff-7",
      state: "pending",
      action: "submit_coding_changes",
      action_type: null,
      resource_title: "acme/widgets",
      resource_url: "/repositories/9",
      app_confirm_path: "/api/v1/app/chats/122/pending_actions/501/confirm",
      app_reject_path: "/api/v1/app/chats/122/pending_actions/501/reject",
      app_cancel_path: "/api/v1/app/chats/122/pending_actions/501"
    }

    expect(pendingActionCardData(action)).toMatchObject({
      label: "Add dark mode toggle",
      detail: "**Branch:** syrus/chat-42-handoff-7",
      resource_title: "acme/widgets",
      resource_url: "/repositories/9"
    })
  })
})
