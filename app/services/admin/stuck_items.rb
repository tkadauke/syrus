module Admin
  # Reconciler-backed "stuck things" watchlist used by the admin overview,
  # dedicated stuck page, token API, and chat MCP admin tools.
  class StuckItems
    ADMIN_STUCK_THRESHOLD = 5.minutes

    Item = Data.define(
      :kind,
      :severity,
      :reconciler_severity,
      :detail,
      :age_label,
      :run,
      :workflow,
      :job,
      :issue,
      :repair_plan,
      :repair_execution,
      :attention_state
    )

    WAITING_ACTIONS = %w[
      diagnose_queue_starvation
      schedule_retry_after_rate_limit
      wait_for_agent_capacity
      wait_for_capacity
      wait_for_dependency_or_stack_readiness
      wait_for_main_health
      wait_for_main_recovery
      wait_for_queue_resume
      wait_for_start_block_to_clear
      retry_or_archive_before_workspace_prune
    ].freeze

    def self.all
      new.all
    end

    def self.for_job(job)
      new(job_id: job.id).all
    end

    def initialize(job_id: nil, now: Time.current)
      @job_id = job_id
      @now = now
    end

    def all
      result.issues.each_with_index.map do |issue, index|
        build_item(issue, result.repair_plans[index], repair_execution_for(result.repair_plans[index]))
      end
    end

    private

    attr_reader :job_id, :now

    def result
      @result ||= WorkEngine::Reconciler.call(source: self.class.name, job_id: job_id, now: now)
    end

    def build_item(issue, repair_plan, repair_execution)
      run = record_for(Run, issue, :run_ids)
      workflow = record_for(Workflow, issue, :workflow_ids) || run&.workflow
      job = record_for(Job, issue, :job_ids) || workflow&.job || run&.job

      Item.new(
        kind: issue.kind,
        severity: severity_for(issue),
        reconciler_severity: issue.severity,
        detail: detail_for(issue, repair_plan, job),
        age_label: age_label_for(age_timestamp(issue, run, workflow, job)),
        run: run,
        workflow: workflow,
        job: job,
        issue: issue,
        repair_plan: repair_plan,
        repair_execution: repair_execution,
        attention_state: attention_state_for(repair_plan, repair_execution)
      )
    end

    def record_for(klass, issue, key)
      id = issue.affected_ids.fetch(key, []).first
      klass.find_by(id: id)
    end

    def repair_execution_for(repair_plan)
      return nil unless repair_plan

      result.repair_executions.find do |execution|
        execution.action == repair_plan.action &&
          execution.target_type == repair_plan.target_type &&
          execution.target_id == repair_plan.target_id
      end
    end

    def severity_for(issue)
      issue.severity.in?(%w[error critical]) ? "alarm" : "warn"
    end

    def attention_state_for(repair_plan, repair_execution)
      return "repaired" if repair_execution&.status == "applied"
      return "operator_action_required" unless repair_plan
      return "auto_repairable" if repair_plan.auto_executable
      return "waiting" if WAITING_ACTIONS.include?(repair_plan.action)

      "operator_action_required"
    end

    def detail_for(issue, repair_plan, job)
      case issue.kind
      when "queued_run_without_queue_claim"
        "Stale queue claim missing: #{issue.explanation} The reconciler can re-enqueue the same Run."
      when "queued_run_stale_queue_claim"
        "Stale queue claim: #{issue.explanation} Waiting avoids duplicating work while the queue claim is investigated."
      when "resource_congestion"
        "Queue starvation or worker capacity pressure: #{issue.explanation}"
      when "dependency_stack_start_block"
        dependency_detail(issue, job)
      when "main_health_start_block"
        "Main health blocked: #{issue.explanation}"
      when "retryable_run_failure"
        "Failed step retryable: #{issue.explanation} #{repair_plan&.reason}"
      when "nonretryable_semantic_git_failure"
        "Operator action required: #{issue.explanation} #{repair_plan&.reason}"
      when "job_without_active_workflow"
        "Operator action required: #{issue.explanation}"
      else
        [ issue.explanation, repair_plan&.reason ].compact.join(" ")
      end.squish
    end

    def dependency_detail(issue, job)
      return "Dependency blocked: #{issue.explanation}" unless job

      unsuccessful = job.unsatisfied_dependencies.select do |dependency|
        dependency.depends_on_job&.closed? && !dependency.dependency_succeeded?
      end
      if unsuccessful.any?
        labels = unsuccessful.map { |dependency| dependency.depends_on_job.slug }.to_sentence
        "Unsuccessful closed dependency: #{job.slug} is blocked because #{labels} closed without a successful dependency resolution."
      else
        "Dependency blocked: #{issue.explanation}"
      end
    end

    def age_timestamp(issue, run, workflow, job)
      [
        issue.evidence["last_heartbeat_at"],
        issue.evidence["started_at"],
        issue.evidence["created_at"],
        issue.evidence["finished_at"],
        issue.evidence["updated_at"],
        run&.last_heartbeat_at,
        run&.started_at,
        workflow&.started_at,
        workflow&.created_at,
        job&.updated_at
      ].compact.filter_map { |value| parse_time(value) }.first
    end

    def age_label_for(time)
      return "-" if time.nil?
      seconds = (now - time).to_i
      return "#{seconds}s" if seconds < 60
      mins = seconds / 60
      return "#{mins}m" if mins < 60
      hours = mins / 60
      return "#{hours}h" if hours < 48
      "#{hours / 24}d"
    end

    def parse_time(value)
      return value.to_time if value.respond_to?(:to_time)

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
