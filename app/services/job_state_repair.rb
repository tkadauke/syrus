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
      WorkUnits::TerminalWorkflowSync.for_job(job)
      job.reload.active_runtime_work?
    end

    def terminal_latest_workflow?
      job.latest_workflow&.state&.in?(%w[succeeded failed cancelled blocked])
    end

    def ready_pr?
      job.pr_number.present? || job.external_pr_number.present?
    end

    def audit!(message)
      run = job.runs.reorder(created_at: :desc, id: :desc).first
      JobLog.append!(run: run, chunk: "[operator repair] #{message}; reason=#{reason}", kind: "system") if run
    rescue StandardError => e
      Rails.logger.warn("[JobStateRepair] audit failed for #{job.slug}: #{e.class}: #{e.message}")
    end
  end

  class Auto < ReconcileMode
    def call
      result = WorkEngine::Reconciler.call_locked!(source: "operator:reconcile_job_state", job_id: job.id, execute_repairs: true)
      unless result
        return Result.new(job: job.reload, message: "A concurrent reconciliation is already running for #{job.slug}; try again shortly.")
      end

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
    EXPECTED_STATES = {
      "retry_after_failure" => %w[queued],
      "queue_reopened_retry" => %w[queued],
      "mark_implemented" => %w[implemented closed],
      "mark_failed" => %w[failed],
      "mark_no_change_needed" => %w[no_change_needed],
      "force_fail" => %w[failed],
      "approve" => %w[approved],
      "unapprove" => %w[implemented],
      "start_landing" => %w[landing],
      "defer_landing" => %w[approved],
      "fail_landing" => %w[implemented],
      "close" => %w[closed],
      "reopen" => %w[triaging]
    }.freeze
    ALLOWED_EVENTS = EXPECTED_STATES.keys.freeze

    def initialize(job:, event:, reason:)
      @job = job
      @event = event.to_s
      @reason = reason.to_s.strip
    end

    def call
      raise ArgumentError, "event is not allowed: #{event}" unless ALLOWED_EVENTS.include?(event)

      ApplicationRecord.transaction do
        job.lock!
        job.reload
        guard = "may_#{event}?"
        raise ArgumentError, "#{job.slug} cannot apply #{event} from #{job.state}" unless job.public_send(guard)

        from_state = job.state
        job.cancel_active_execution!(reason: Workflow::SUPERSEDED_BY_STATE_REPAIR_REASON) if terminal_event?
        job.reload
        raise ArgumentError, "#{job.slug} cannot apply #{event} from #{job.state} after runtime cleanup" unless job.public_send(guard)

        StateTransition.with_source("reconciler") do
          applied = job.public_send("#{event}!")
          raise ArgumentError, "#{job.slug} did not apply #{event} from #{job.state}" unless applied

          job.save!
        end
        job.reload
        unless EXPECTED_STATES.fetch(event).include?(job.state)
          raise ArgumentError, "#{job.slug} applied #{event} but reached unexpected state #{job.state}"
        end

        audit!(from_state)
        Result.new(job: job, message: "Applied #{event} to #{job.slug}: #{from_state} -> #{job.state}.")
      end
    end

    private

    attr_reader :job, :event, :reason

    def terminal_event?
      event.in?(%w[mark_implemented mark_failed mark_no_change_needed force_fail close])
    end

    def audit!(from_state)
      run = job.runs.reorder(created_at: :desc, id: :desc).first
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] forced Job event #{event}: #{from_state} -> #{job.state}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
