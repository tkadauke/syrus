module AgentQuestions
  class FileFixJob
    Result = Data.define(:job)

    def self.call(job:, actor:)
      job.with_lock do
        existing = existing_fix(job)
        return Result.new(job: existing) if existing

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
          Result.new(job: fix)
        end
      end
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
    private_class_method :existing_fix, :fix_title, :prompt_for
  end
end
