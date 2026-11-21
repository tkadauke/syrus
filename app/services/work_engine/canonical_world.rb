module WorkEngine
  # Exports work-engine state in the canonical schema the DOC-44 Lean kernel
  # and its executable oracle (formal/Oracle.lean, `syrus_oracle`) read:
  # WorkIntent → WorkUnit → Workflow → Step → Run plus active locks, with
  # states as the kernel's state names and every other column left out.
  #
  # Scoped to the given Jobs' records (all records when no Jobs are given), so
  # a conformance check can compare the Ruby reconciler and the oracle on the
  # same world. Read-only.
  class CanonicalWorld
    SCHEMA_VERSION = 1

    def self.export(jobs: nil) = new(jobs:).export

    def initialize(jobs: nil)
      @jobs = jobs
    end

    def export
      {
        "intents" => intents.map { |intent| { "id" => intent.id, "state" => intent.state } },
        "units" => units.map do |unit|
          { "id" => unit.id, "intent" => unit.work_intent_id, "workflow" => unit.workflow_id, "state" => unit.state }
        end,
        "workflows" => workflows.map { |workflow| { "id" => workflow.id, "state" => workflow.state } },
        "steps" => steps.map { |step| { "id" => step.id, "workflow" => step.workflow_id, "state" => step.state } },
        "runs" => runs.map { |run| { "id" => run.id, "step" => run.step_id, "state" => run.state } },
        "locks" => locks.map { |lock| { "key" => lock.lock_key, "unit" => lock.work_unit_id } }
      }
    end

    private

    attr_reader :jobs

    def job_workflow_ids
      @job_workflow_ids ||= (jobs ? Workflow.where(job: jobs) : Workflow.all).pluck(:id)
    end

    # Units owning one of the Jobs' Workflows, plus units that only list the
    # Jobs as members (a unit without a Workflow is still part of the world).
    def units
      @units ||= if jobs
        WorkUnit.where(workflow_id: job_workflow_ids)
          .or(WorkUnit.where(id: WorkUnitMember.where(job: jobs).select(:work_unit_id)))
          .order(:id).to_a
      else
        WorkUnit.order(:id).to_a
      end
    end

    # The Jobs' Workflows and every exported unit's own Workflow, so no unit
    # points outside the world (the kernel's Valid requires it).
    def workflows
      @workflows ||= Workflow.where(id: job_workflow_ids + units.filter_map(&:workflow_id)).order(:id).to_a
    end

    def steps
      @steps ||= Step.where(workflow_id: workflows.map(&:id)).order(:id).to_a
    end

    def runs
      @runs ||= Run.where(step_id: steps.map(&:id)).order(:id).to_a
    end

    def intents
      @intents ||= WorkIntent.where(id: units.map(&:work_intent_id)).order(:id).to_a
    end

    def locks
      @locks ||= WorkUnitLock.active.where(work_unit_id: units.map(&:id)).order(:id).to_a
    end
  end
end
