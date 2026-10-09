require "mcp"

module Mcp::Tools
  # Lets a workflow agent end the current Step as blocked when it has verified
  # that the requested work cannot proceed in this environment or with the
  # available workflow surface. The tool records operator-visible evidence;
  # RunJob performs the actual terminal state transition after the agent turn
  # returns so the provider process shuts down normally.
  class ReportCannotProceedTool < MCP::Tool
    tool_name "report_cannot_proceed"

    MAX_REASON_LENGTH = 500
    MAX_DETAILS_LENGTH = 4_000
    MAX_WARNING_TITLE_LENGTH = 255

    description <<~DESC
      Report that the current workflow step cannot proceed for a concrete,
      non-transient reason. Use this only after checking the blocker, such as
      a required binary missing from the worker image or an instruction that
      asks for a workflow capability that is not available. Syrus will mark the
      Run, Step, and Workflow blocked instead of failed, will not retry the
      step automatically, and will surface the reason for operator attention.
    DESC

    input_schema(
      properties: {
        reason: {
          type: "string",
          description: "Concise operator-facing reason, under #{MAX_REASON_LENGTH} characters."
        },
        details: {
          type: "string",
          description: "Optional extra context or evidence in markdown, under #{MAX_DETAILS_LENGTH} characters."
        },
        suggested_prompt: {
          type: "string",
          description: "Optional prompt for the operator's File a fix Job action."
        }
      },
      required: %w[reason]
    )

    class << self
      def call(reason:, details: nil, suggested_prompt: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :report_cannot_proceed)

        normalized_reason = Mcp::Tools.utf8(reason).strip.truncate(MAX_REASON_LENGTH)
        normalized_details = Mcp::Tools.utf8(details).strip.truncate(MAX_DETAILS_LENGTH)
        normalized_prompt = Mcp::Tools.utf8(suggested_prompt).strip.presence || default_suggested_prompt(run, normalized_reason, normalized_details)
        return Mcp::Tools.invalid("reason is required") if normalized_reason.empty?

        payload = {
          "reason" => normalized_reason,
          "details" => normalized_details,
          "run_id" => run.id,
          "step_id" => run.step_id,
          "reported_at" => Time.current.iso8601
        }.compact_blank

        run.workflow.set_artifact!("cannot_proceed", payload)
        warning = record_warning!(run, payload, normalized_prompt)
        run.job.set_needs_attention!(reason: "agent_cannot_proceed")
        Mcp::Tools.write_log(run, "[mcp] report_cannot_proceed: #{normalized_reason}")

        MCP::Tool::Response.new([ {
          type: "text",
          text: "Recorded cannot-proceed reason. Stop work now; Syrus will mark this step blocked when your turn ends. Warning ##{warning.id} is visible on the Job."
        } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::ReportCannotProceedTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def record_warning!(run, payload, suggested_prompt)
        WorkflowWarnings.record!(
          workflow: run.workflow,
          step: run.step,
          kind: "agent_cannot_proceed",
          severity: "high",
          title: "Agent cannot proceed: #{payload.fetch('reason')}".truncate(MAX_WARNING_TITLE_LENGTH),
          evidence: payload,
          suggested_prompt: suggested_prompt
        )
      end

      def default_suggested_prompt(run, reason, details)
        sections = [
          "Resolve the workflow blocker reported by #{run.workflow.slug} step #{run.step.slug}: #{reason}",
          details.presence
        ].compact
        sections.join("\n\n")
      end
    end
  end
end
