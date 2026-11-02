module Maintenance
  class RepairNonOsPlannedExecutionCapabilities
    Result = Data.define(:job_ids, :workflow_ids)
    NOT_STARTED_JOB_STATES = %w[needs_triage triaging backlog blocked_by_epic queued].freeze

    def self.call = new.call

    def call
      repaired_jobs = []
      repaired_workflows = []

      Job.where(state: NOT_STARTED_JOB_STATES).find_each do |job|
        next unless forbidden_keys(job.planned_execution_capabilities).any?

        repair_job!(job)
        repaired_jobs << job.id
      end

      Workflow.where(state: "queued").find_each do |workflow|
        next unless forbidden_keys(workflow.planned_execution_capabilities).any?

        repair_workflow!(workflow)
        repaired_workflows << workflow.id
      end

      redispatch!(repaired_workflows)
      Result.new(job_ids: repaired_jobs, workflow_ids: repaired_workflows)
    end

    private

    def forbidden_keys(capabilities)
      capabilities.to_h.stringify_keys.keys - PlannedExecutionRequirement::PERMITTED_CAPABILITY_KEYS
    end

    def repaired_capabilities(capabilities)
      os = capabilities.to_h.stringify_keys["os"].presence || PlannedExecutionRequirement::DEFAULT_CAPABILITIES["os"]
      PlannedExecutionRequirement.normalize_capabilities("os" => os)
    end

    def repair_job!(job)
      previous = placement_for(job)
      replacement = previous.merge("capabilities" => repaired_capabilities(job.planned_execution_capabilities))

      Job.transaction do
        job.update_columns(planned_execution_capabilities: replacement.fetch("capabilities"), updated_at: Time.current)
        PlannedExecutionOverride.create!(
          job: job, workflow: nil, user: job.user, profile: "os_only_data_repair",
          reason: "Removed forbidden non-OS worker admission capabilities from not-yet-started work.",
          provenance: "data_migration", previous_placement: previous, replacement_placement: replacement
        )
      end
    end

    def repair_workflow!(workflow)
      previous = placement_for(workflow)
      replacement = previous.merge("capabilities" => repaired_capabilities(workflow.planned_execution_capabilities))
      Workflow.transaction do
        workflow.update_columns(
          planned_execution_capabilities: replacement.fetch("capabilities"),
          updated_at: Time.current
        )
        PlannedExecutionOverride.create!(
          job: workflow.job, workflow: workflow, user: workflow.user, profile: "os_only_data_repair",
          reason: "Removed forbidden non-OS worker admission capabilities from queued work.",
          provenance: "data_migration", previous_placement: previous, replacement_placement: replacement
        )
      end
    end

    def placement_for(record)
      {
        "project_label" => record.planned_execution_project_label,
        "target_label" => record.planned_execution_target_label,
        "capabilities" => record.planned_execution_capabilities,
        "source" => record.planned_execution_source
      }
    end

    def redispatch!(workflow_ids)
      Workflow.where(id: workflow_ids).find_each do |workflow|
        StepDispatcher.clear_start_blocked!(workflow, RunQueueResolver::BLOCKED_OUTCOME)
        unit = workflow.work_unit
        unit&.unblock! if unit&.blocked_reason == RunQueueResolver::BLOCKED_OUTCOME
        runs = workflow.runs.where(state: "queued").to_a
        runs.any? ? runs.each(&:reenqueue!) : WorkUnits::Launcher.start!(workflow)
      rescue StandardError => e
        Rails.logger.error("[Maintenance::RepairNonOsPlannedExecutionCapabilities] redispatch failed for Workflow##{workflow.id}: #{e.class}: #{e.message}")
        WorkEngine::Reconciler.request(source: self.class.name, job: workflow.job)
      end
    end
  end
end
