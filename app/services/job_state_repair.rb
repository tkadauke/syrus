class JobStateRepair
  Result = Data.define(:job, :message)

  def self.reconcile!(...) = ReconcileMode.for(...).call
  def self.force_transition!(...) = ForceTransition.new(...).call

  class ReconcileMode
    def self.for(mode:, **)
      registry.fetch(mode.to_s) { raise ArgumentError, "unknown reconciliation mode: #{mode}" }.new(**)
    end

    def self.registry
      @registry ||= descendants.index_by(&:mode)
    end

    def self.mode = name.demodulize.underscore

    def initialize(job:, reason:)
      @job = job
      @reason = reason.to_s.strip
    end

    def call
      raise NotImplementedError
    end

    private

    attr_reader :job, :reason

    def with_job_lock
      job.with_lock do
        job.reload
        yield
      end
    end

    def apply_events!(*events)
      StateTransition.with_source("reconciler") do
        events.each do |event|
          guard = "may_#{event}?"
          raise ArgumentError, "#{job.slug} cannot apply #{event} from #{job.state}" unless job.public_send(guard)

          job.public_send("#{event}!")
          job.save!
        end
      end
    end

    def active_work?
      job.any_active_run? || job.workflows.active.exists?
    end

    def terminal_latest_workflow?
      job.latest_workflow&.state&.in?(%w[succeeded failed cancelled])
    end

    def ready_pr?
      job.pr_number.present? || job.external_pr_number.present?
    end

    def audit!(message)
      run = job.runs.order(created_at: :desc, id: :desc).first
      JobLog.append!(run: run, chunk: "[operator repair] #{message}; reason=#{reason}", kind: "system") if run
    rescue StandardError => e
      Rails.logger.warn("[JobStateRepair] audit failed for #{job.slug}: #{e.class}: #{e.message}")
    end
  end

  class Auto < ReconcileMode
    def call
      result = WorkEngine::Reconciler.call(source: "operator:reconcile_job_state", job_id: job.id, execute_repairs: true)
      Result.new(job: job.reload, message: "WorkEngine reconciler inspected #{result.issues.size} issue(s) and applied #{result.repair_executions.count { |execution| execution.status == "applied" }} repair(s).")
    end
  end

  class MarkImplementedFromReadyPr < ReconcileMode
    def call
      with_job_lock do
        raise ArgumentError, "#{job.slug} has no PR recorded." unless ready_pr?
        raise ArgumentError, "#{job.slug} still has active work." if active_work?
        raise ArgumentError, "#{job.slug} has no terminal latest workflow." unless terminal_latest_workflow?

        from_state = job.state
        if job.failed?
          apply_events!(:retry_after_failure, :mark_implemented)
        elsif job.queued? || job.running?
          apply_events!(:mark_implemented)
        else
          raise ArgumentError, "#{job.slug} is #{job.state}; expected queued, running, or failed."
        end

        audit!("reconciled Job state #{from_state} -> #{job.state} from ready PR")
        Result.new(job: job, message: "Marked #{job.slug} implemented from its ready PR.")
      end
    end
  end

  class MarkFailed < ReconcileMode
    def call
      with_job_lock do
        raise ArgumentError, "#{job.slug} still has active work." if active_work?

        from_state = job.state
        if job.running?
          apply_events!(:mark_failed)
        elsif job.queued?
          apply_events!(:start_running, :mark_failed)
        else
          raise ArgumentError, "#{job.slug} is #{job.state}; expected queued or running."
        end

        audit!("reconciled Job state #{from_state} -> #{job.state}")
        Result.new(job: job, message: "Marked #{job.slug} failed.")
      end
    end
  end

  class MarkQueued < ReconcileMode
    def call
      with_job_lock do
        raise ArgumentError, "#{job.slug} still has active work." if active_work?
        raise ArgumentError, "#{job.slug} cannot be marked queued from #{job.state}." unless job.may_retry_after_failure?

        from_state = job.state
        apply_events!(:retry_after_failure)
        audit!("reconciled Job state #{from_state} -> #{job.state}")
        Result.new(job: job, message: "Marked #{job.slug} queued.")
      end
    end
  end

  class ForceTransition
    ALLOWED_EVENTS = %w[
      retry_after_failure
      queue_reopened_retry
      mark_implemented
      mark_failed
      mark_no_change_needed
      force_fail
      approve
      unapprove
      start_landing
      defer_landing
      fail_landing
      close
      reopen
    ].freeze

    def initialize(job:, event:, reason:)
      @job = job
      @event = event.to_s
      @reason = reason.to_s.strip
    end

    def call
      raise ArgumentError, "event is not allowed: #{event}" unless ALLOWED_EVENTS.include?(event)

      job.with_lock do
        job.reload
        guard = "may_#{event}?"
        raise ArgumentError, "#{job.slug} cannot apply #{event} from #{job.state}" unless job.public_send(guard)

        from_state = job.state
        StateTransition.with_source("reconciler") do
          job.public_send("#{event}!")
          job.save!
        end
        audit!(from_state)
        Result.new(job: job, message: "Applied #{event} to #{job.slug}: #{from_state} -> #{job.state}.")
      end
    end

    private

    attr_reader :job, :event, :reason

    def audit!(from_state)
      run = job.runs.order(created_at: :desc, id: :desc).first
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] forced Job event #{event}: #{from_state} -> #{job.state}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
