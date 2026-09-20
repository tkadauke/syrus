module WorkflowWarnings
  # Creates the `direct` Job behind a WorkflowWarning's "File a fix Job"
  # button, from the (possibly operator-edited) suggested_prompt. Mirrors
  # AgentInsights::Proposals::CreateJob's shape — the closest existing
  # analog — but this is a separate, single-purpose flow, not a modification
  # of the agent_insights accept action.
  class FileFixJob
    PROCESS_MUTEX = Mutex.new

    Result = Struct.new(:ok?, :message, :warning, :job, keyword_init: true) do
      def self.ok(warning:, job:)
        new(ok?: true, message: "Fix Job #{job.slug} filed.", warning: warning, job: job)
      end

      def self.error(message)
        new(ok?: false, message: message)
      end
    end

    def self.call(warning:, actor:, prompt:)
      existing_job = warning.created_job
      return Result.ok(warning: warning, job: existing_job) if existing_job.present?

      prompt_text = prompt.to_s.strip
      return Result.error("Prompt can't be blank.") if prompt_text.blank?

      created_job = PROCESS_MUTEX.synchronize do
        warning.with_lock do
          warning.reload
          if warning.created_job.present?
            warning.created_job
          else
            repository = warning.job.repository
            job = actor.jobs.create!(
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
            job.advance_after_triage! if job.may_advance_after_triage?

            warning.update!(created_job: job)
            job
          end
        end
      end

      Result.ok(warning: warning.reload, job: created_job)
    end
  end
end
