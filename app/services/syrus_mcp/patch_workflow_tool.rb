require "mcp"

module SyrusMcp
  # Lets an implementing agent add a check to its own workflow
  # (workflow-engine-v3 A7).
  #
  # This is the mechanism Steps::GraderFanout and Try-branch expansion already
  # use, made explicit and attributable. It is deliberately the last thing the
  # plan builds, and it is narrow on purpose: an agent can add work to itself,
  # never remove work, and never grant itself the ability to publish.
  # WorkflowPatch enforces all three, so a prompt-injected or simply mistaken
  # agent cannot patch away the checks it is being held to.
  #
  # Permanent customization is not this: that is a repo-local
  # `.syrus/workflows/<key>.yml` written through the pending-action
  # confirmation flow, where a person sees it first.
  class PatchWorkflowTool < MCP::Tool
    tool_name "patch_workflow"

    description <<~DESC
      Adds one or more steps to the workflow you are currently running.

      Use this when the work you are doing turns out to need a check the
      template did not include -- for example adding a visual_review after
      implementing a UI change.

      Append-only. You cannot remove a step, and you cannot add a step that
      publishes (pr_open, push, auto_merge, and similar); attempts are refused
      and recorded. The patch is attributed to you and visible on the workflow.
    DESC

    input_schema(
      properties: {
        step_kinds: {
          type: "array",
          items: { type: "string" },
          description: "Step kinds to add, in order (e.g. ['visual_review'])."
        },
        after_kind: {
          type: "string",
          description: "Insert after this step kind. Omitted appends to the end of the chain."
        },
        reason: {
          type: "string",
          description: "One sentence on why this workflow needs the extra step."
        }
      },
      required: %w[step_kinds reason]
    )

    class << self
      def call(step_kinds:, reason:, after_kind: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :patch_workflow)

        kinds = Array(step_kinds).map { |kind| Mcp::Tools.utf8(kind).strip }.reject(&:empty?)
        return Mcp::Tools.invalid("step_kinds is required") if kinds.empty?
        return Mcp::Tools.invalid("reason is required") if Mcp::Tools.utf8(reason).strip.empty?

        result = WorkflowPatch.apply!(
          workflow: run.workflow,
          operation: "insert_after",
          author: "agent",
          nodes: kinds,
          after_kind: after_kind.presence,
          reason: Mcp::Tools.utf8(reason).strip
        )

        return Mcp::Tools.invalid(result.reason) unless result.applied?

        Mcp::Tools.success(added: kinds, after: after_kind, chain: WorkflowTemplates.step_kinds_in(result.graph))
      end
    end
  end
end
