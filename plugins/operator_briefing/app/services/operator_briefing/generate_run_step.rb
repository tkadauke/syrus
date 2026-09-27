module OperatorBriefing
  class GenerateRunStep < ::Steps::Base
    GENERATION_TURN_BUDGET = 25

    def call
      workspace.setup
      revision = create_revision!
      persist_prompt_if_needed(revision)
      log("invoking agent for briefing_generate_run step (#{workflow.slug})")
      run_agent(
        prompt: run.prompt,
        max_turns: GENERATION_TURN_BUDGET,
        required_mcp_tools: %w[submit_briefing_block]
      )
      verify_blocks_submitted!(revision)
    end

    private

    def create_revision!
      briefing.revisions.create!(
        revision_number: briefing.revisions.maximum(:revision_number).to_i + 1,
        generated_at: Time.current,
        generation_run: run,
        content_blocks: []
      )
    end

    def persist_prompt_if_needed(revision)
      return if run.prompt.present?

      run.update!(prompt: Prompt.new(briefing: briefing, revision: revision, user: job.user).to_s)
    end

    def briefing
      @briefing ||= Briefing.find_by!(job: job)
    end

    def verify_blocks_submitted!(revision)
      return if revision.reload.content_blocks.any?

      capture_mcp_sidecar_stderr
      raise StepFailed, "agent didn't call submit_briefing_block"
    end
  end
end
