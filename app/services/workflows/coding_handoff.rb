module Workflows
  # Post-coding-mode handoff: runs graders on the code the chat agent wrote,
  # then opens (or updates) the PR. Instantiated by the complete_implement_step
  # MCP tool once the agent commits and pushes from the chat workspace.
  #
  # Chain: prepare → grader_fanout → grader_collect → summarize → test_plan → pr_open
  #
  # No retry-until loop: grader failures surface back to the owning chat session
  # via linked_chat_id (handled by the cm-grader workflow). linked_chat_id is
  # intentionally preserved on the Job so that future grader-routing code can
  # deliver results to the right session.
  class CodingHandoff < Base
    def self.trigger_kind = "coding_handoff"

    def self.steps_for(job)
      chain = [ "prepare", "grader_fanout", "grader_collect", "summarize", "test_plan", "pr_open" ]
      prepare_skipped_for?(job) ? chain.reject { |s| s == "prepare" } : chain
    end

    def self.prepare_skipped_for?(job)
      job.skip_prepare?
    end
  end
end
