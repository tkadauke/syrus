require "mcp"

module SyrusMcp
  # MCP tool for insight agents to record a discovered pattern or improvement
  # suggestion as an InsightSuggestion record. Scope-enforced: evidence
  # job_ids must belong to repositories accessible to the run's user.
  # Admin users may reference jobs across any repository they control.
  class SubmitInsightTool < MCP::Tool
    SEVERITIES = InsightSuggestion::SEVERITIES.freeze

    tool_name "submit_insight"

    description <<~DESC
      Records a discovered improvement suggestion on the current insight Job.
      Call once per distinct finding. Evidence job_ids must belong to
      repositories accessible to the running user.
    DESC

    input_schema(
      properties: {
        title: {
          type: "string",
          description: "Concise title summarizing the finding (≤ 200 chars)."
        },
        category: {
          type: "string",
          description: "Finding category, e.g. repeated_failure, inefficiency, configuration, memory_gap, recurring_task."
        },
        severity: {
          type: "string",
          enum: SEVERITIES,
          description: "Severity: low, medium, or high."
        },
        confidence: {
          type: "number",
          description: "Confidence that this is a real pattern (0.0–1.0)."
        },
        evidence: {
          type: "array",
          description: "Array of {job_id, run_id, kind} objects supporting the finding.",
          items: {
            type: "object",
            properties: {
              job_id: { type: "integer" },
              run_id: { type: "integer" },
              kind:   { type: "string" }
            }
          }
        },
        suggested_prompt: {
          type: "string",
          description: "Optional prompt text for a Job or ScheduledTask that would address the finding."
        },
        memory_suggestion: {
          type: "string",
          description: "Optional exact text to store as a memory for future agents."
        }
      },
      required: %w[title category severity confidence]
    )

    class << self
      MAX_TITLE_LENGTH = 200

      def call(title:, category:, severity:, confidence:, server_context:,
               evidence: nil, suggested_prompt: nil, memory_suggestion: nil)
        run = SyrusMcp.run_from_context(server_context)

        title_s     = SyrusMcp.utf8(title).strip
        category_s  = SyrusMcp.utf8(category).strip
        severity_s  = SyrusMcp.utf8(severity).strip
        confidence_f = confidence.to_f

        return SyrusMcp.invalid("title is required")                              if title_s.empty?
        return SyrusMcp.invalid("title too long (#{title_s.length} chars)")       if title_s.length > MAX_TITLE_LENGTH
        return SyrusMcp.invalid("category is required")                           if category_s.empty?
        return SyrusMcp.invalid("severity must be one of: #{SEVERITIES.join(', ')}") unless SEVERITIES.include?(severity_s)
        return SyrusMcp.invalid("confidence must be between 0.0 and 1.0")         unless confidence_f.between?(0.0, 1.0)

        normalized_evidence = normalize_evidence(evidence)
        scope_error = validate_evidence_scope(normalized_evidence, run)
        return SyrusMcp.invalid(scope_error) if scope_error

        suggestion = InsightSuggestion.create!(
          job:               run.job,
          repository:        run.job.repository,
          title:             title_s,
          category:          category_s,
          severity:          severity_s,
          confidence:        confidence_f,
          evidence:          normalized_evidence.presence,
          suggested_prompt:  suggested_prompt.presence,
          memory_suggestion: memory_suggestion.presence
        )

        insights = Array(run.workflow.artifact("insights"))
        insights << {
          "id"       => suggestion.id,
          "title"    => suggestion.title,
          "category" => suggestion.category,
          "severity" => suggestion.severity
        }
        run.workflow.set_artifact!("insights", insights)

        SyrusMcp.write_log(run, "[mcp] submit_insight: #{title_s.truncate(80)} (#{severity_s})")

        MCP::Tool::Response.new([ { type: "text", text: "InsightSuggestion ##{suggestion.id} saved." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitInsightTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalize_evidence(evidence)
        return [] unless evidence.is_a?(Array)

        evidence.map do |entry|
          next unless entry.is_a?(Hash)

          {
            "job_id" => entry["job_id"]&.to_i,
            "run_id" => entry["run_id"]&.to_i,
            "kind"   => entry["kind"].to_s.presence
          }.compact
        end.compact
      end

      # Returns an error string if any evidence job_id is not accessible to
      # the run's user, nil otherwise. Admins bypass the check.
      def validate_evidence_scope(evidence, run)
        job_ids = evidence.filter_map { |e| e["job_id"] }.uniq
        return nil if job_ids.empty?

        user = run.job.user
        return nil if user.admin?

        accessible_ids = user.jobs.where(id: job_ids).pluck(:id)
        foreign_ids    = job_ids - accessible_ids
        return nil if foreign_ids.empty?

        "evidence references jobs not accessible to this user: #{foreign_ids.join(', ')}"
      end
    end
  end
end
