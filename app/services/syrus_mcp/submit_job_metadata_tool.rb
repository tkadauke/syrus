require "mcp"

module SyrusMcp
  # Stores canonical Job/PR review metadata on the current Workflow.
  # This is deliberately separate from submit_summary, whose follow-up
  # semantics drive amendment commit messages.
  class SubmitJobMetadataTool < MCP::Tool
    tool_name "submit_job_metadata"

    description <<~DESC
      Stores canonical Job and PR review metadata for a feedback workflow.
      Use changed=false when the feedback was a narrow fix that does not change
      the Job's effective intent. Use changed=true only when title, summary, PR
      body, and test plan should replace the top-level Job/PR review copy.
    DESC

    input_schema(
      properties: {
        changed: {
          type: "boolean",
          description: "Whether the Job's canonical intent/review metadata changed."
        },
        title: {
          type: "string",
          description: "Canonical Job/PR title when changed=true. Concise, specific, and materially related to the current Job."
        },
        summary: {
          type: "string",
          description: "Operator-facing top-level Job summary when changed=true."
        },
        pr_body: {
          type: "string",
          description: "Canonical PR body when changed=true. Markdown, no managed Syrus footers."
        },
        test_plan: {
          type: "object",
          properties: {
            steps: {
              type: "array",
              items: { type: "string" }
            },
            notes: { type: "string" }
          }
        },
        intent_revision_reason: {
          type: "string",
          description: "Short audit note explaining why metadata changed, or why no change was needed."
        }
      },
      required: %w[changed]
    )

    class << self
      MAX_TITLE_LENGTH = 120

      def call(changed:, title: nil, summary: nil, pr_body: nil, test_plan: nil, intent_revision_reason: nil, server_context:)
        run = SyrusMcp.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return SyrusMcp.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_job_metadata)
        return SyrusMcp.not_authorized unless run.step&.kind == "refresh_job_metadata"

        changed = ActiveModel::Type::Boolean.new.cast(changed)
        normalized = normalize_payload(
          changed: changed,
          title: title,
          summary: summary,
          pr_body: pr_body,
          test_plan: test_plan,
          intent_revision_reason: intent_revision_reason
        )

        validation_error = validate_payload(normalized)
        return SyrusMcp.invalid(validation_error) if validation_error

        run.workflow.set_artifact!("job_metadata", normalized)
        SyrusMcp.write_log(run, "[mcp] submit_job_metadata received: changed=#{changed}")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitJobMetadataTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalize_payload(changed:, title:, summary:, pr_body:, test_plan:, intent_revision_reason:)
        {
          "changed" => changed,
          "title" => SyrusMcp.utf8(title).strip.presence,
          "summary" => SyrusMcp.utf8(summary).strip.presence,
          "pr_body" => SyrusMcp.utf8(pr_body).strip.presence,
          "test_plan" => normalize_test_plan(test_plan),
          "intent_revision_reason" => SyrusMcp.utf8(intent_revision_reason).strip.presence,
          "submitted_at" => Time.current.iso8601
        }.compact
      end

      def normalize_test_plan(test_plan)
        return nil unless test_plan.is_a?(Hash)

        steps = Array(test_plan["steps"] || test_plan[:steps]).map { |step| SyrusMcp.utf8(step).strip }.reject(&:empty?)
        notes = SyrusMcp.utf8(test_plan["notes"] || test_plan[:notes]).strip.presence
        return nil if steps.empty? && notes.blank?

        { "steps" => steps, "notes" => notes }.compact
      end

      def validate_payload(payload)
        return nil unless payload["changed"]

        return "title is required when changed=true" if payload["title"].blank?
        return "title too long (#{payload['title'].length} chars)" if payload["title"].length > MAX_TITLE_LENGTH
        return "summary is required when changed=true" if payload["summary"].blank?
        return "pr_body is required when changed=true" if payload["pr_body"].blank?
        return "test_plan.steps must include at least one item when changed=true" if Array(payload.dig("test_plan", "steps")).empty?

        nil
      end
    end
  end
end
