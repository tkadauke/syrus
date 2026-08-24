module WorkEngine
  class ReconcilerActivity
    def self.record_run_started!(...)
      new(...).record_run_started!
    end

    def self.record_result!(...)
      new(...).record_result!
    end

    def self.record_failure!(...)
      new(...).record_failure!
    end

    def initialize(source:, job_id: nil, workflow_id: nil, run_id: nil, work_intent_id: nil, now: Time.current, execute_repairs: false, result: nil, error: nil)
      @source = source.to_s
      @job_id = job_id
      @workflow_id = workflow_id
      @run_id = run_id
      @work_intent_id = work_intent_id
      @now = now
      @execute_repairs = !!execute_repairs
      @result = result
      @error = error
    end

    def record_run_started!
      return unless execute_repairs

      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_started",
        source: source,
        occurred_at: now,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        message: "Reconciler started#{context_description}.",
        details: { execute_repairs: execute_repairs, work_intent_id: work_intent_id }.compact
      )
    end

    def record_result!
      return unless result

      if execute_repairs
        actionable_activity.each do |issue, plan, execution|
          record_issue!(issue)
          record_plan!(plan)
          record_execution!(execution)
        end
      end

      return unless execute_repairs
      return unless notable_result?

      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_finished",
        source: source,
        occurred_at: result.captured_at,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        severity: result.issues.any? ? "warn" : "info",
        message: "Reconciler finished#{context_description}: #{result.issues.size} issue(s), #{result.repair_plans.size} plan(s), #{result.repair_executions.size} execution(s).",
        details: {
          execute_repairs: execute_repairs,
          work_intent_id: work_intent_id,
          issues_count: result.issues.size,
          repair_plans_count: result.repair_plans.size,
          repair_executions_count: result.repair_executions.size,
          issue_kinds: result.issues.map(&:kind).tally,
          repair_actions: result.repair_plans.map(&:action).tally,
          repair_statuses: result.repair_executions.map(&:status).tally
        }
      )
    end

    def record_failure!
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_failed",
        source: source,
        occurred_at: now,
        job_id: job_id,
        workflow_id: workflow_id,
        run_id: run_id,
        severity: "error",
        message: "Reconciler failed#{context_description}: #{error.class}: #{error.message}",
        details: { execute_repairs: execute_repairs, work_intent_id: work_intent_id, error_class: error.class.name, error_message: error.message }.compact
      )
    end

    private

    attr_reader :source, :job_id, :workflow_id, :run_id, :work_intent_id, :now, :execute_repairs, :result, :error

    def notable_result?
      actionable_activity.any?
    end

    def actionable_activity
      result.repair_executions.each_with_index.filter_map do |execution, index|
        next if execution.status == "skipped"

        [ result.issues[index], result.repair_plans[index], execution ]
      end
    end

    def record_issue!(issue)
      return unless issue

      ids = normalized_ids(issue.affected_ids)
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "issues_detected",
        source: source,
        occurred_at: result.captured_at,
        severity: severity_for_issue(issue),
        job_id: ids[:job_id],
        workflow_id: ids[:workflow_id],
        step_id: ids[:step_id],
        run_id: ids[:run_id],
        issue_kind: issue.kind,
        repair_action: issue.recommended_repair_action,
        message: issue.explanation,
        details: {
          safe_to_auto_repair: issue.safe_to_auto_repair,
          retry_after: issue.retry_after&.iso8601,
          check_after: issue.check_after&.iso8601,
          affected_ids: issue.affected_ids,
          evidence: issue.evidence
        }
      )
    end

    def record_plan!(plan)
      return unless plan

      ids = normalized_ids(plan.affected_ids)
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "repair_planned",
        source: source,
        occurred_at: result.captured_at,
        severity: plan.auto_executable ? "info" : "warn",
        job_id: ids[:job_id],
        workflow_id: ids[:workflow_id],
        step_id: ids[:step_id],
        run_id: ids[:run_id],
        issue_kind: plan.issue_kind,
        repair_action: plan.action,
        message: plan.reason,
        details: plan.as_json.except(:reason)
      )
    end

    def record_execution!(execution)
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "repair_executed",
        source: source,
        occurred_at: result.captured_at,
        severity: execution.status == "failed" ? "error" : "info",
        repair_action: execution.action,
        repair_status: execution.status,
        message: execution.message,
        **contextual_target_ids(execution),
        details: execution.as_json
      )
    end

    def normalized_ids(ids)
      ids = (ids || {}).with_indifferent_access
      {
        job_id: Array(ids[:job_ids]).first,
        workflow_id: Array(ids[:workflow_ids]).first,
        step_id: Array(ids[:step_ids]).first,
        run_id: Array(ids[:run_ids]).first
      }
    end

    def contextual_target_ids(execution)
      case execution.target_type
      when "Job"
        { job_id: execution.target_id }
      when "Workflow"
        workflow = Workflow.find_by(id: execution.target_id)
        { job_id: workflow&.job_id, workflow_id: execution.target_id }
      when "Step"
        step = Step.includes(:workflow).find_by(id: execution.target_id)
        { job_id: step&.workflow&.job_id, workflow_id: step&.workflow_id, step_id: execution.target_id }
      when "Run"
        run = Run.includes(step: :workflow).find_by(id: execution.target_id)
        { job_id: run&.job_id, workflow_id: run&.step&.workflow_id, step_id: run&.step_id, run_id: execution.target_id }
      else {}
      end
    end

    def severity_for_issue(issue)
      issue.severity == "alarm" ? "alarm" : "warn"
    end

    def context_description
      parts = []
      parts << "Job ##{job_id}" if job_id.present?
      parts << "Workflow ##{workflow_id}" if workflow_id.present?
      parts << "Run ##{run_id}" if run_id.present?
      parts.empty? ? "" : " for #{parts.join(", ")}"
    end
  end
end
