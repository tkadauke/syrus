module WorkflowWarnings
  # Creates the `direct` Job behind a WorkflowWarning's "File a fix Job"
  # button, from the (possibly operator-edited) suggested_prompt. Mirrors
  # InsightSuggestions::Proposals::CreateJob's shape — the closest existing
  # analog — but this is a separate, single-purpose flow, not a modification
  # of the InsightSuggestion accept action.
  class FileFixJob
    Result = Struct.new(:ok?, :message, :warning, :job, keyword_init: true) do
      def self.ok(warning:, job:)
        new(ok?: true, message: "Fix Job #{job.slug} filed.", warning: warning, job: job)
      end

      def self.error(message)
        new(ok?: false, message: message)
      end
    end

    def self.call(warning:, actor:, prompt:)
      prompt_text = prompt.to_s.strip
      return Result.error("Prompt can't be blank.") if prompt_text.blank?

      repository = warning.job.repository
      created_job = actor.jobs.create!(
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: warning.title.truncate(120),
        title_pending: false,
        issue_body: prompt_text,
        agent_provider: repository.effective_agent_provider,
        priority: "medium",
        state: Job.initial_state_for_creator(actor)
      )
      created_job.advance_after_triage! if created_job.may_advance_after_triage?

      warning.file_fix_job!(created_job)

      Result.ok(warning: warning.reload, job: created_job)
    end
  end
end
