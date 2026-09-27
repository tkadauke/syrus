module OperatorBriefing
  class GenerateRunStep < ::Steps::Base
    def call
      workspace.setup
      revision = create_revision!
      persist_prompt_if_needed(revision)
      log("invoking agent for briefing_generate_run step (#{workflow.slug})")
      run_agent(prompt: run.prompt, required_mcp_tools: %w[submit_briefing_block])
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
  end
end
