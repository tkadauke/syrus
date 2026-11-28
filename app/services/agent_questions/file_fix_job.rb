module AgentQuestions
  class FileFixJob
    class RetryFailed < StandardError; end

    Result = Data.define(:job)

    def self.call(job:, actor:)
      expected_question_workflow_id = question_workflow(job)&.id
      fix = Job.transaction do
        Lineage.lock_active_work!(job)
        lock_active_questions!(job, expected_question_workflow_id) if expected_question_workflow_id
        job.reload(lock: true)

        retry_mode = question_retry_mode(job)
        if expected_question_workflow_id && !retry_mode
          raise RetryFailed, I18n.t("agent_questions.errors.inactive")
        end
        if retry_mode && !(preflight = retry_mode.preflight).eligible?
          raise RetryFailed, preflight.message
        end

        existing = existing_fix(job)
        fix = existing || begin
          created = actor.jobs.create!(
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
            depends_on_job: created,
            satisfaction_mode: "landed",
            source: "manual",
            created_by_user: actor
          )
          created.advance_after_triage! if created.may_advance_after_triage?
          created
        end

        if retry_mode && !(retry_result = retry_mode.execute).success?
          raise RetryFailed, retry_result.error
        end

        fix
      end

      Result.new(job: fix)
    end

    def self.question_workflow(job)
      workflow = job.latest_workflow
      workflow if workflow&.running? && workflow.active_agent_questions?
    end

    def self.question_retry_mode(job)
      return unless question_workflow(job)

      RetryJobs::Modes::Implementation.new(job: job, explicit_operator_intent: true)
    end

    def self.lock_active_questions!(job, workflow_id)
      run_ids = Run.joins(:step).where(job_id: job.id, steps: { workflow_id: workflow_id }).select(:id)
      AgentQuestion.active.where(run_id: run_ids).lock.to_a
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
    private_class_method :question_workflow, :question_retry_mode, :lock_active_questions!, :existing_fix, :fix_title, :prompt_for
  end
end
