require "mcp"

module Mcp::Tools
  class InvestigationProposeJobTool < MCP::Tool
    extend ProposalToolSupport

    MAX_PROPOSALS_PER_WORKFLOW = 10
    # Implementation, feedback and CI repair agents should rarely need this:
    # most of what they find belongs in the Job they are working on.
    MAX_IMPLEMENTATION_PROPOSALS_PER_WORKFLOW = 3
    INVESTIGATION_STEP_KINDS = %w[investigate submit_report].freeze

    tool_name "propose_job"

    description <<~DESC
      Propose one follow-up Job for work you found that is outside the
      current Job. The Job is created immediately in triaging with
      triaging_reason=proposed_job; it does not start until an operator
      accepts it from the Job page. Use it only for concrete work, not for
      Epics or additional investigations.

      Never use it to hand off part of the current Job: anything its
      description or acceptance criteria ask for must be done here.
      Reviewers see every follow-up you propose and treat one that belongs
      in this Job as unfinished work. Proposing the same title twice from
      this Job returns the existing proposal.

      planned_execution.capabilities is REQUIRED. #{ProposeJobTool::REQUIRED_PLACEMENT_MESSAGE}
    DESC

    input_schema(
      properties: {
        title: { type: "string", description: "Follow-up Job title." },
        description: { type: "string", description: "Markdown Job description. Use real newline characters for paragraphs and lists." },
        planned_execution: {
          type: "object",
          properties: {
            project_label: { type: "string", description: "Optional operator-facing project or placement label." },
            target_label: { type: "string", description: "Optional target graph label, such as //web:app." },
            capabilities: { type: "object", description: "Execution capabilities. Only os is supported, with values linux or macos." },
            source: { type: "string", description: "Decision provenance. Defaults to explicit for investigation-authored proposals." }
          },
          description: "Explicit primary implementation placement. planned_execution.capabilities is required."
        }
      },
      required: %w[title description planned_execution]
    )

    class << self
      def call(title:, description:, planned_execution:, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :propose_job)

        title = Mcp::Tools.utf8(title).strip
        description = normalize_proposal_markdown(Mcp::Tools.utf8(description)).strip
        return Mcp::Tools.invalid("title is required") if title.empty?
        return Mcp::Tools.invalid("description is required") if description.empty?

        planned_execution_attrs = planned_execution_attributes(planned_execution)
        return Mcp::Tools.invalid(planned_execution_attrs) if planned_execution_attrs.is_a?(String)

        workflow = run.workflow
        source_job = run.job
        investigation = run.step&.kind.in?(INVESTIGATION_STEP_KINDS)
        existing = previously_proposed_job(source_job, title)
        return success_response(existing, source_job, already_proposed: true) if existing

        proposed_ids = Array(workflow.artifact("proposed_job_ids")).filter_map { |id| Integer(id, exception: false) }
        limit = investigation ? MAX_PROPOSALS_PER_WORKFLOW : MAX_IMPLEMENTATION_PROPOSALS_PER_WORKFLOW
        if proposed_ids.size >= limit
          scope = investigation ? "an investigation workflow" : "a workflow"
          return Mcp::Tools.invalid("#{scope} may propose at most #{limit} Jobs")
        end

        job = nil
        ApplicationRecord.transaction do
          job = source_job.user.jobs.create!(
            repository: source_job.repository,
            kind: "direct",
            issue_number: nil,
            issue_title: title,
            issue_body: body_with_source(description, source_job, investigation:),
            job_provider_setting: source_job.job_provider_setting,
            agent_provider: source_job.workflow_agent_provider,
            priority: source_job.priority.presence || "medium",
            state: "triaging",
            triaging_reason: "proposed_job",
            **planned_execution_attrs
          )
          workflow.set_artifact!("proposed_job_ids", proposed_ids.push(job.id))
        end

        Mcp::Tools.write_log(run, "[mcp] propose_job created #{job.slug} awaiting triage")
        success_response(job, source_job)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::InvestigationProposeJobTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def planned_execution_attributes(planned_execution)
        return ProposeJobTool::REQUIRED_PLACEMENT_MESSAGE unless explicit_planned_execution_capabilities?(planned_execution)

        source = planned_execution.to_h.deep_stringify_keys
        source["source"] = "explicit" if source["source"].blank? && source["planned_execution_source"].blank?
        explicit = PlannedExecutionParams.from_params({ "planned_execution" => source })
        return explicit if explicit.present?

        ProposeJobTool::REQUIRED_PLACEMENT_MESSAGE
      end

      def success_response(job, source_job, already_proposed: false)
        Mcp::Tools.success(
          id: job.id,
          slug: job.slug,
          title: job.issue_title,
          state: job.state,
          triaging_reason: job.triaging_reason,
          planned_execution: job.planned_execution_json,
          already_proposed: already_proposed,
          source_job: {
            id: source_job.id,
            slug: source_job.slug,
            title: source_job.issue_title
          }
        )
      end

      # Retries and review rounds re-run the same agent over the same Job; a
      # follow-up it already proposed and the operator has not yet triaged is
      # the same proposal, not a new one.
      def previously_proposed_job(source_job, title)
        ids = source_job.workflows.flat_map { |workflow| Array(workflow.artifact("proposed_job_ids")) }
          .filter_map { |id| Integer(id, exception: false) }
        return nil if ids.empty?

        Job.where(id: ids, state: "triaging", triaging_reason: "proposed_job")
          .find { |job| job.issue_title.to_s.strip.casecmp?(title) }
      end

      def body_with_source(description, source_job, investigation:)
        origin = investigation ? "Proposed by investigation" : "Proposed during work on"
        <<~MARKDOWN.strip
          #{description}

          ---

          #{origin} [#{source_job.slug}](/jobs/#{source_job.id}): #{source_job.issue_title}
        MARKDOWN
      end
    end
  end
end
