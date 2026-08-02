require "mcp"

module SyrusMcp
  # MCP tool for insight agents to record a discovered pattern or improvement
  # suggestion as an InsightSuggestion record. Scope-enforced: evidence
  # job_ids must belong to repositories accessible to the run's user.
  # Admin users may reference jobs across any repository they control.
  class SubmitInsightTool < MCP::Tool
    SEVERITIES = InsightSuggestion::SEVERITIES.freeze
    PROPOSAL_TYPES = InsightSuggestion::PROPOSAL_TYPES.freeze

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
        },
        proposal_type: {
          type: "string",
          enum: PROPOSAL_TYPES,
          description: "Action proposed by this insight: create_job, save_memory, remove_memory, revise_existing_insight, or informational."
        },
        target_memory_id: {
          type: "integer",
          description: "Required for remove_memory proposals. The ChatMemory id that should be removed if an operator accepts."
        },
        stale_memory_text: {
          type: "string",
          description: "For remove_memory proposals, the stale or wrong memory text being challenged."
        },
        stale_memory_evidence: {
          type: "string",
          description: "For remove_memory proposals, explain why the memory no longer matches current code, docs, jobs, or accepted state."
        },
        target_insight_id: {
          type: "integer",
          description: "For revise_existing_insight proposals, the existing InsightSuggestion id that is stale, duplicated, or superseded."
        }
      },
      required: %w[title category severity confidence]
    )

    class << self
      MAX_TITLE_LENGTH = 200

      def call(title:, category:, severity:, confidence:, server_context:,
               evidence: nil, suggested_prompt: nil, memory_suggestion: nil,
               proposal_type: nil, target_memory_id: nil, stale_memory_text: nil,
               stale_memory_evidence: nil, target_insight_id: nil)
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

        proposal_type_s = normalize_proposal_type(proposal_type, suggested_prompt: suggested_prompt, memory_suggestion: memory_suggestion)
        return SyrusMcp.invalid("proposal_type must be one of: #{PROPOSAL_TYPES.join(', ')}") unless PROPOSAL_TYPES.include?(proposal_type_s)

        normalized_evidence = normalize_evidence(evidence)
        scope_error = validate_evidence_scope(normalized_evidence, run)
        return SyrusMcp.invalid(scope_error) if scope_error

        memory = nil
        if proposal_type_s == "remove_memory"
          memory = validate_target_memory(target_memory_id, run)
          return SyrusMcp.invalid("target_memory_id must reference an active accessible repository memory") unless memory
          return SyrusMcp.invalid("stale_memory_evidence is required for remove_memory proposals") if stale_memory_evidence.to_s.strip.blank?
        end

        target_insight = nil
        if proposal_type_s == "revise_existing_insight"
          target_insight = validate_target_insight(target_insight_id, run)
          return SyrusMcp.invalid("target_insight_id must reference an accessible insight") unless target_insight
        end

        suggestion = InsightSuggestion.create!(
          job:               run.job,
          repository:        run.job.repository,
          title:             title_s,
          category:          category_s,
          severity:          severity_s,
          confidence:        confidence_f,
          proposal_type:     proposal_type_s,
          evidence:          normalized_evidence.presence,
          suggested_prompt:  suggested_prompt.presence,
          memory_suggestion: memory_suggestion.presence,
          target_memory:     memory,
          stale_memory_text: stale_memory_text.presence || memory&.content,
          stale_memory_evidence: stale_memory_evidence.presence,
          target_insight:    target_insight
        )
        SupervisorEvents.publish!(
          kind: "agent_insight_available",
          severity: severity_s == "high" ? "warning" : "info",
          subject: "Agent Insight available",
          repository: suggestion.repository,
          actor: run,
          summary: "#{suggestion.title} (#{suggestion.severity}, #{(suggestion.confidence * 100).round}% confidence)",
          details: {
            "insight_suggestion_id" => suggestion.id,
            "job_id" => run.job_id,
            "run_id" => run.id,
            "category" => suggestion.category
          },
          dedupe_key: "agent_insight_available:#{suggestion.id}"
        )

        insights = Array(run.workflow.artifact("insights"))
        insights << {
          "id"       => suggestion.id,
          "title"    => suggestion.title,
          "category" => suggestion.category,
          "severity" => suggestion.severity,
          "proposal_type" => suggestion.effective_proposal_type
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

      def normalize_proposal_type(value, suggested_prompt:, memory_suggestion:)
        explicit = value.to_s.presence
        return explicit if explicit
        return "create_job" if suggested_prompt.present?
        return "save_memory" if memory_suggestion.present?

        "informational"
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

      def validate_target_memory(memory_id, run)
        id = Integer(memory_id, exception: false)
        return unless id

        scope = ChatMemory.active.where(id: id)
        return scope.first if run.job.user.admin?

        scope.find_by(user_id: run.job.user_id, scope: "repository", scope_id: run.job.repository_id)
      end

      def validate_target_insight(insight_id, run)
        id = Integer(insight_id, exception: false)
        return unless id

        scope = InsightSuggestion.where(id: id)
        return scope.first if run.job.user.admin?

        scope.find_by(repository_id: run.job.repository_id)
      end
    end
  end
end
