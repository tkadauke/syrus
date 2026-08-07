require "mcp"

module Mcp::Tools
  # MCP tool for insight agents to revise an existing unaccepted insight in
  # place. Accepted insights are treated as immutable operator history; agents
  # must submit a new insight when new evidence changes an accepted one.
  class UpdateInsightTool < MCP::Tool
    SEVERITIES = InsightSuggestion::SEVERITIES.freeze
    PROPOSAL_TYPES = (InsightSuggestion::PROPOSAL_TYPES - %w[revise_existing_insight]).freeze
    NOT_PROVIDED = Object.new.freeze

    tool_name "update_insight"

    description <<~DESC
      Updates an existing unaccepted InsightSuggestion in place. Use this when
      a pending or dismissed insight is stale, duplicated, incomplete, or
      superseded. If the target insight is accepted, this tool rejects the
      update; submit a new standalone insight instead and cite the accepted
      insight as context if useful.
    DESC

    input_schema(
      properties: {
        target_insight_id: {
          type: "integer",
          description: "Required InsightSuggestion id to update."
        },
        reason: {
          type: "string",
          description: "Required concise reason for the audit trail."
        },
        title: {
          type: "string",
          description: "Revised concise title (≤ 200 chars)."
        },
        category: {
          type: "string",
          description: "Revised category."
        },
        severity: {
          type: "string",
          enum: SEVERITIES,
          description: "Revised severity: low, medium, or high."
        },
        confidence: {
          type: "number",
          description: "Revised confidence (0.0–1.0)."
        },
        evidence: {
          type: "array",
          description: "Replacement array of {job_id, run_id, kind} evidence objects.",
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
          description: "Replacement prompt text, or null to clear."
        },
        memory_suggestion: {
          type: "string",
          description: "Replacement memory suggestion text, or null to clear."
        },
        proposal_type: {
          type: "string",
          enum: PROPOSAL_TYPES,
          description: "Replacement proposal type: create_job, save_memory, remove_memory, or informational."
        },
        target_memory_id: {
          type: "integer",
          description: "Required when changing/keeping proposal_type as remove_memory."
        },
        stale_memory_text: {
          type: "string",
          description: "Replacement stale memory text for remove_memory insights."
        },
        stale_memory_evidence: {
          type: "string",
          description: "Replacement explanation for remove_memory insights."
        }
      },
      required: %w[target_insight_id reason]
    )

    class << self
      MAX_TITLE_LENGTH = 200

      def call(target_insight_id:, reason:, server_context:,
               title: NOT_PROVIDED, category: NOT_PROVIDED, severity: NOT_PROVIDED,
               confidence: NOT_PROVIDED, evidence: NOT_PROVIDED,
               suggested_prompt: NOT_PROVIDED, memory_suggestion: NOT_PROVIDED,
               proposal_type: NOT_PROVIDED, target_memory_id: NOT_PROVIDED,
               stale_memory_text: NOT_PROVIDED, stale_memory_evidence: NOT_PROVIDED)
        run = Mcp::Tools.run_from_context(server_context)
        reason_s = Mcp::Tools.utf8(reason).strip
        return Mcp::Tools.invalid("reason is required") if reason_s.empty?

        insight = visible_insight(target_insight_id, run)
        return Mcp::Tools.invalid("target_insight_id must reference an accessible insight") unless insight

        if insight.accepted?
          return Mcp::Tools.invalid(
            "InsightSuggestion ##{insight.id} is accepted and cannot be updated. Submit a new insight instead and cite the accepted insight as context."
          )
        end

        attrs_or_response = normalized_attributes(
          run: run,
          current: insight,
          title: title,
          category: category,
          severity: severity,
          confidence: confidence,
          evidence: evidence,
          suggested_prompt: suggested_prompt,
          memory_suggestion: memory_suggestion,
          proposal_type: proposal_type,
          target_memory_id: target_memory_id,
          stale_memory_text: stale_memory_text,
          stale_memory_evidence: stale_memory_evidence
        )
        return attrs_or_response if attrs_or_response.is_a?(MCP::Tool::Response)

        if attrs_or_response.empty?
          return Mcp::Tools.invalid("at least one insight field must be provided to update")
        end

        previous_values = {}
        new_values = {}
        insight.with_lock do
          if insight.accepted?
            return Mcp::Tools.invalid(
              "InsightSuggestion ##{insight.id} is accepted and cannot be updated. Submit a new insight instead and cite the accepted insight as context."
            )
          end

          attrs_or_response.each do |field, value|
            old_value = insight.public_send(field)
            next if old_value == value

            previous_values[field] = old_value
            new_values[field] = value
          end

          return Mcp::Tools.invalid("provided values do not change the target insight") if new_values.empty?

          insight.update!(attrs_or_response)
          InsightSuggestionAuditEvent.record!(
            insight_suggestion: insight,
            event_type: "updated",
            actor: run,
            previous_values: previous_values,
            new_values: new_values,
            reason: reason_s
          )
        end

        append_workflow_artifact(run, insight)
        Mcp::Tools.write_log(run, "[mcp] update_insight: ##{insight.id} #{insight.title.truncate(80)}")

        MCP::Tool::Response.new([
          { type: "text", text: "InsightSuggestion ##{insight.id} updated." }
        ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::UpdateInsightTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalized_attributes(run:, current:, **values)
        attrs = {}

        if provided?(values[:title])
          title_s = Mcp::Tools.utf8(values[:title]).strip
          return Mcp::Tools.invalid("title is required") if title_s.empty?
          return Mcp::Tools.invalid("title too long (#{title_s.length} chars)") if title_s.length > MAX_TITLE_LENGTH
          attrs["title"] = title_s
        end

        if provided?(values[:category])
          category_s = Mcp::Tools.utf8(values[:category]).strip
          return Mcp::Tools.invalid("category is required") if category_s.empty?
          attrs["category"] = category_s
        end

        if provided?(values[:severity])
          severity_s = Mcp::Tools.utf8(values[:severity]).strip
          return Mcp::Tools.invalid("severity must be one of: #{SEVERITIES.join(', ')}") unless SEVERITIES.include?(severity_s)
          attrs["severity"] = severity_s
        end

        if provided?(values[:confidence])
          confidence_f = values[:confidence].to_f
          return Mcp::Tools.invalid("confidence must be between 0.0 and 1.0") unless confidence_f.between?(0.0, 1.0)
          attrs["confidence"] = confidence_f
        end

        if provided?(values[:evidence])
          normalized_evidence = normalize_evidence(values[:evidence])
          return Mcp::Tools.invalid("evidence must include at least one non-empty item or be omitted") if normalized_evidence.empty?
          scope_error = validate_evidence_scope(normalized_evidence, run)
          return Mcp::Tools.invalid(scope_error) if scope_error
          attrs["evidence"] = normalized_evidence
        end

        if provided?(values[:suggested_prompt])
          attrs["suggested_prompt"] = string_or_nil(values[:suggested_prompt])
        end
        if provided?(values[:memory_suggestion])
          attrs["memory_suggestion"] = string_or_nil(values[:memory_suggestion])
        end

        if provided?(values[:proposal_type])
          proposal_type_s = Mcp::Tools.utf8(values[:proposal_type]).strip
          return Mcp::Tools.invalid("proposal_type must be one of: #{PROPOSAL_TYPES.join(', ')}") unless PROPOSAL_TYPES.include?(proposal_type_s)
          attrs["proposal_type"] = proposal_type_s
          attrs["target_insight_id"] = nil
        end

        if provided?(values[:target_memory_id])
          memory = validate_target_memory(values[:target_memory_id], run)
          return Mcp::Tools.invalid("target_memory_id must reference an active accessible repository memory") if values[:target_memory_id].present? && !memory
          attrs["target_memory_id"] = memory&.id
        end
        attrs["stale_memory_text"] = string_or_nil(values[:stale_memory_text]) if provided?(values[:stale_memory_text])
        attrs["stale_memory_evidence"] = string_or_nil(values[:stale_memory_evidence]) if provided?(values[:stale_memory_evidence])

        effective_type = attrs.fetch("proposal_type", current.proposal_type)
        if effective_type == "remove_memory"
          effective_memory_id = attrs.key?("target_memory_id") ? attrs["target_memory_id"] : current.target_memory_id
          effective_stale_evidence = attrs.key?("stale_memory_evidence") ? attrs["stale_memory_evidence"] : current.stale_memory_evidence
          return Mcp::Tools.invalid("target_memory_id must reference an active accessible repository memory") if effective_memory_id.blank?
          return Mcp::Tools.invalid("stale_memory_evidence is required for remove_memory proposals") if effective_stale_evidence.blank?
        end

        attrs
      end

      def provided?(value)
        !value.equal?(NOT_PROVIDED)
      end

      def string_or_nil(value)
        return nil if value.nil?

        Mcp::Tools.utf8(value).strip.presence
      end

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

      def integer_value(hash, key)
        Integer(hash[key] || hash[key.to_sym], exception: false)
      end

      def string_value(hash, key)
        value = hash[key] || hash[key.to_sym]
        value.to_s
      end

      def visible_insight(insight_id, run)
        id = Integer(insight_id, exception: false)
        return unless id

        InsightSuggestion.for_repository(run.job.repository).find_by(id: id)
      end

      def validate_target_memory(memory_id, run)
        id = Integer(memory_id, exception: false)
        return unless id

        ChatMemory.active.find_by(
          id: id,
          user_id: run.job.user_id,
          scope: "repository",
          scope_id: run.job.repository_id
        )
      end

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

      def append_workflow_artifact(run, insight)
        updates = Array(run.workflow.artifact("insight_updates"))
        updates << {
          "id" => insight.id,
          "title" => insight.title,
          "category" => insight.category,
          "severity" => insight.severity,
          "proposal_type" => insight.effective_proposal_type
        }
        run.workflow.set_artifact!("insight_updates", updates)
      end
    end
  end
end
