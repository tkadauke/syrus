module App
  class MergeTrainStatus
    PHASE_BY_STEP = {
      "merge_train_assemble" => "assembling",
      "merge_train_build" => "assembling",
      "merge_train_reconcile" => "reconciling",
      "prepare" => "grading",
      "grader_fanout" => "grading",
      "grader" => "grading",
      "grader_collect" => "grading",
      "landing_fix" => "grading",
      "merge_train_land" => "landing",
      "merge_train_rebase" => "landing",
      "merge_train_land_after_rebase" => "landing"
    }.freeze

    PHASE_BY_TRAIN_STATE = {
      "building" => "assembling",
      "grading" => "grading",
      "landing" => "landing",
      "failed" => "failed",
      "cancelled" => "failed",
      "succeeded" => "landed"
    }.freeze

    def self.for_epic(epic) = new(epic).payload
    def self.for_job(job) = job.epic ? for_epic(job.epic) : nil

    def initialize(epic)
      @epic = epic
    end

    def payload
      train = current_train
      return unless train

      workflow = workflow_for(train)
      step = current_step(workflow)
      {
        id: train.id,
        state: train.state,
        phase: phase(train, workflow, step),
        branch: train.integration_branch,
        member_count: train.members.size,
        workflow_id: workflow&.id,
        workflow_state: workflow&.state,
        current_step_kind: step&.kind,
        current_step_label: step && Step::Kind.label_for(step.kind),
        reconciliation: reconciliation_status(workflow),
        failure_reason: train.failure_reason.presence || workflow&.failure_reason.presence
      }
    end

    private

    def current_train
      MergeTrain.where(epic_id: @epic.id)
                .where.not(state: "succeeded")
                .order(id: :desc)
                .first
    end

    def workflow_for(train)
      Workflow.where(trigger_kind: "merge_train", job_id: train.jobs.select(:id))
              .order(id: :desc)
              .detect { |workflow| workflow.artifact("merge_train_id").to_i == train.id }
    end

    def current_step(workflow)
      return unless workflow

      workflow.current_step || workflow.steps.where(state: "queued").order(:position).first || workflow.steps.order(:position).last
    end

    def phase(train, workflow, step)
      return "failed" if %w[failed cancelled].include?(train.state) || workflow&.failed? || workflow&.cancelled?

      PHASE_BY_STEP[step&.kind] || PHASE_BY_TRAIN_STATE[train.state] || train.state
    end

    def reconciliation_status(workflow)
      return unless workflow

      step = workflow.steps.find_by(kind: "merge_train_reconcile")
      return unless step

      latest_run = step.runs.order(:created_at, :id).last
      result = if step.succeeded?
        latest_run&.step_agent_diff.present? ? "committed" : "no_changes"
      elsif step.failed?
        "failed"
      elsif step.running?
        "running"
      end

      {
        step_id: step.id,
        state: step.state,
        result: result,
        run_id: latest_run&.id,
        head_sha: latest_run&.head_sha,
        diff_bytes: latest_run&.step_agent_diff&.bytesize || 0
      }
    end
  end
end
