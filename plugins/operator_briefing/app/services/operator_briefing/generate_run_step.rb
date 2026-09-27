module OperatorBriefing
  class GenerateRunStep < ::Steps::Base
    RECENT_JOB_LIMIT = 5
    NOTABLE_CHANGE_LIMIT = 10
    GENERATION_TURN_BUDGET = 25

    def call
      workspace.setup
      briefing = Briefing.find_by!(job: job)
      revision = create_revision!(briefing)
      persist_prompt_if_needed(briefing)

      log("invoking agent for operator briefing revision #{revision.revision_number} (#{workflow.slug})")
      run_agent(
        prompt: run.prompt,
        max_turns: GENERATION_TURN_BUDGET,
        required_mcp_tools: %w[submit_briefing_block]
      )

      verify_blocks_submitted!(revision)
      log("created operator briefing revision #{revision.revision_number} for #{repository.slug}")
    end

    private

    def create_revision!(briefing)
      briefing.revisions.create!(
        revision_number: briefing.revisions.maximum(:revision_number).to_i + 1,
        generated_at: Time.current,
        generation_run: run,
        content_blocks: []
      )
    end

    def persist_prompt_if_needed(briefing)
      return if run.prompt.present?

      run.update!(prompt: generation_prompt(briefing))
    end

    def generation_prompt(briefing)
      <<~PROMPT
        You are generating the live Operator Briefing for #{repository.slug}.

        The page is watching for streamed briefing blocks. Do not wait until the
        end and do not return the briefing as your final answer. For each section
        you produce, call `submit_briefing_block` immediately with that section's
        typed block.

        Use only these supported block kinds:
        - `narrative` with payload `{ "text": "..." }`
        - `link_card` with payload fields for `entity_type`, `entity_id`,
          `title`, `path`, and `description`

        The current deterministic source pass found these candidate blocks. You
        may tighten wording, reorder, or omit low-value blocks, but preserve the
        structured link_card references when you mention those entities.

        ```json
        #{JSON.pretty_generate(content_blocks(briefing))}
        ```

        Call `submit_briefing_block` once per final block, in display order. When
        all blocks have been submitted, stop.
      PROMPT
    end

    def verify_blocks_submitted!(revision)
      return if revision.reload.content_blocks.any?

      capture_mcp_sidecar_stderr
      raise StepFailed, "agent didn't call submit_briefing_block"
    end

    def content_blocks(briefing)
      preferences = source_preferences(briefing)
      [
        narrative_block(briefing, preferences),
        *recent_job_cards(briefing, preferences),
        *notable_change_cards(briefing, preferences)
      ]
    end

    def narrative_block(briefing, preferences)
      changes_count = source_enabled?(preferences, "notable_changes") ? notable_changes_scope(briefing).count : 0
      review_count = source_enabled?(preferences, "review_findings") ? review_findings_scope(briefing).count : 0
      jobs_count = source_enabled?(preferences, "jobs") ? recent_jobs_scope(briefing).count : 0
      text = if changes_count.zero? && review_count.zero? && jobs_count.zero?
        "No notable activity was found for #{repository.slug} in this briefing window."
      else
        "Briefing window for #{repository.slug}: #{jobs_count} recent Jobs, #{changes_count} notable workflow changes, and #{review_count} review findings."
      end

      payload = { "text" => text }
      memory_context = personalization_memory_context(briefing)
      payload["personalization_memory_context"] = memory_context if memory_context.present?
      { "kind" => "narrative", "payload" => payload }
    end

    def recent_job_cards(briefing, preferences)
      return [] unless source_enabled?(preferences, "jobs")

      recent_jobs_scope(briefing).limit(RECENT_JOB_LIMIT).map do |recent_job|
        link_card(
          entity_type: "job",
          entity_id: recent_job.id,
          title: recent_job.issue_title.presence || recent_job.slug,
          path: "/jobs/#{recent_job.id}",
          description: "#{recent_job.kind.humanize} / #{recent_job.state}"
        )
      end
    end

    def notable_change_cards(briefing, preferences)
      return [] unless source_enabled?(preferences, "notable_changes")

      notable_changes_scope(briefing).limit(NOTABLE_CHANGE_LIMIT).map do |change|
        link_card(
          entity_type: "workflow",
          entity_id: change.workflow_id,
          title: change.summary,
          path: "/jobs/#{change.job_id}?tab=workflows#workflow-#{change.workflow_id}",
          description: change.severity.humanize
        )
      end
    end

    def source_preferences(briefing)
      SourcePreference.effective_for_user(briefing.owner_user)
    end

    def source_enabled?(preferences, source_key)
      preferences.fetch(source_key).enabled?
    end

    def personalization_memory_context(briefing)
      AgentMemory::PromptContext.new(user: briefing.owner_user, repository_ids: [ repository.id ]).to_s
    end

    def link_card(entity_type:, entity_id:, title:, path:, description:)
      {
        "kind" => "link_card",
        "payload" => {
          "entity_type" => entity_type,
          "entity_id" => entity_id,
          "title" => title,
          "path" => path,
          "description" => description
        }
      }
    end

    def recent_jobs_scope(briefing)
      repository.jobs
        .where.not(kind: ActivityGate::EXCLUDED_JOB_KINDS)
        .where("jobs.created_at >= :start_at AND jobs.created_at <= :end_at", start_at: briefing.window_start, end_at: briefing.window_end)
        .order(created_at: :desc, id: :desc)
    end

    def notable_changes_scope(briefing)
      WorkflowNotableChange
        .where(repository: repository)
        .where(created_at: briefing.window_start..briefing.window_end)
        .order(created_at: :desc, id: :desc)
    end

    def review_findings_scope(briefing)
      ReviewFinding
        .joins(workflow: :job)
        .where(jobs: { repository_id: repository.id })
        .where(operator_briefing_review_findings: { created_at: briefing.window_start..briefing.window_end })
    end
  end
end
