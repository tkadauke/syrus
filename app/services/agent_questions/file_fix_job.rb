module AgentQuestions
  class FileFixJob
    class RetryFailed < StandardError; end

    Result = Data.define(:job)

    def self.call(job:, actor:)
      retry_mode = question_retry_mode(job)
      if retry_mode && !(preflight = retry_mode.preflight).eligible?
        raise RetryFailed, preflight.message
      end

      fix = job.with_lock do
        existing = existing_fix(job)
        next existing if existing

        Job.transaction do
          fix = actor.jobs.create!(
            repository: job.repository,
            kind: "direct",
            issue_number: nil,
            issue_title: fix_title(job),
            title_pending: false,
            issue_body: prompt_for(job),
            priority: job.priority,
            state: Job.initial_state_for_creator(actor)
          )
          job.dependencies.create!(
            depends_on_job: fix,
            satisfaction_mode: "landed",
            source: "manual",
            created_by_user: actor
          )
          fix.advance_after_triage! if fix.may_advance_after_triage?
          fix
        end
      end

      if retry_mode && !(retry_result = retry_mode.execute).success?
        raise RetryFailed, retry_result.error
      end

      Result.new(job: fix)
    end

    def self.question_retry_mode(job)
      workflow = job.latest_workflow
      return unless workflow&.running? && workflow.active_agent_questions?

      RetryJobs::Modes::Implementation.new(job: job, explicit_operator_intent: true)
    end

    def self.existing_fix(job)
      job.dependencies.includes(:depends_on_job).map(&:depends_on_job).compact.find do |candidate|
        candidate.direct? && candidate.issue_title == fix_title(job)
      end
    end

    def self.fix_title(job) = "Fix blocker for #{job.slug}"

    def self.prompt_for(job)
      reason = job.needs_attention_reason.to_s.presence || "the current workflow is blocked"
      <<~PROMPT.strip
        Resolve the blocker preventing #{job.slug} from continuing.

        Reported reason: #{reason}

        Fix the underlying problem so the dependent Job can resume after this Job lands.
      PROMPT
    end
    private_class_method :question_retry_mode, :existing_fix, :fix_title, :prompt_for
  end
end
