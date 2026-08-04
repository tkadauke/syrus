require "mcp"

module SyrusMcp
  # MCP tool for insight agents to record a discovered pattern or improvement
  # suggestion as an InsightSuggestion record. Scope-enforced: evidence
  # job_ids and run_ids must belong to the current run's repository.
  class SubmitInsightTool < MCP::Tool
    SEVERITIES = InsightSuggestion::SEVERITIES.freeze
    PROPOSAL_TYPES = InsightSuggestion::PROPOSAL_TYPES.freeze

    tool_name "submit_insight"

    description <<~DESC
      Records a discovered improvement suggestion on the current insight Job.
      Call once per distinct finding. Evidence job_ids must belong to
      the current run's repository.
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
        return SyrusMcp.invalid("evidence must include at least one non-empty item or be omitted") if evidence_supplied?(evidence) && normalized_evidence.empty?

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
          job: run.job,
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

        evidence.filter_map do |entry|
          next unless entry.is_a?(Hash)

          normalized = {
            "job_id" => integer_value(entry, "job_id"),
            "run_id" => integer_value(entry, "run_id"),
            "kind"   => string_value(entry, "kind").presence
          }.compact

          normalized.presence
        end
      end

      def evidence_supplied?(evidence)
        !evidence.nil?
      end

      def integer_value(hash, key)
        Integer(hash[key] || hash[key.to_sym], exception: false)
      end

      def string_value(hash, key)
        value = hash[key] || hash[key.to_sym]
        value.to_s
      end

      def normalize_proposal_type(value, suggested_prompt:, memory_suggestion:)
        explicit = value.to_s.presence
        return explicit if explicit
        return "create_job" if suggested_prompt.present?
        return "save_memory" if memory_suggestion.present?

        "informational"
      end

      # Returns an error string if evidence references jobs or runs outside
      # the current repository scope, or if a run_id is paired with the wrong
      # job_id. Run-sidecar insight reads are repository-scoped, so writes use
      # the same boundary even for admin users.
      def validate_evidence_scope(evidence, run)
        job_ids = evidence.filter_map { |e| e["job_id"] }.uniq
        run_ids = evidence.filter_map { |e| e["run_id"] }.uniq
        return nil if job_ids.empty? && run_ids.empty?

        repository_id = run.job.repository_id

        jobs_by_id = Job.where(id: job_ids, repository_id: repository_id).index_by(&:id)
        inaccessible_job_ids = job_ids - jobs_by_id.keys
        if inaccessible_job_ids.any?
          return "evidence references jobs outside the current repository scope: #{inaccessible_job_ids.join(', ')}"
        end

        runs_by_id = Run
          .includes(:job)
          .where(id: run_ids, jobs: { repository_id: repository_id })
          .references(:job)
          .index_by(&:id)
        inaccessible_run_ids = run_ids - runs_by_id.keys
        if inaccessible_run_ids.any?
          return "evidence references runs outside the current repository scope: #{inaccessible_run_ids.join(', ')}"
        end

        evidence.each do |entry|
          next unless entry["job_id"] && entry["run_id"]

          evidence_run = runs_by_id[entry["run_id"]]
          next if evidence_run&.job_id == entry["job_id"]

          return "evidence run_id #{entry['run_id']} does not belong to job_id #{entry['job_id']}"
        end

        nil
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
