class MergeTrainMultisectWorkflow
  STARTED_ARTIFACT_KEY = "merge_train_multisect_started".freeze
  COMPLETED_ARTIFACT_KEY = "merge_train_multisect_completed".freeze
  COLLECT_KIND = "merge_train_multisect_collect".freeze
  EVALUATE_KIND = "merge_train_multisect_evaluate".freeze
  PREPARE_KIND = "merge_train_multisect_prepare".freeze

  def self.insert_after_failure!(workflow:, train:, failed_step:)
    new(workflow: workflow, train: train).insert_after_failure!(failed_step: failed_step)
  end

  def self.append_collect_with_evaluations!(after_step:, collect_details:, evaluations:)
    new(workflow: after_step.workflow, train: train_for(after_step.workflow)).append_collect_with_evaluations!(
      after_step: after_step,
      collect_details: collect_details,
      evaluations: evaluations
    )
  end

  def self.train_for(workflow)
    MergeTrain.find(workflow.artifact("merge_train_id"))
  end

  def initialize(workflow:, train:)
    @workflow = workflow
    @train = train
  end

  def insert_after_failure!(failed_step:)
    return false if workflow.artifact(STARTED_ARTIFACT_KEY).present?
    return false if workflow.artifact(COMPLETED_ARTIFACT_KEY).present?

    prepare = nil
    Step.transaction do
      continuation = failed_step.next_step
      insertion_position = failed_step.position + 1
      workflow.steps.where("position >= ?", insertion_position).update_all([ "position = position + ?", 2 ])
      prepare = Step.create!(
        workflow: workflow,
        kind: PREPARE_KIND,
        position: insertion_position,
        placement_policy: control_plane_policy,
        depends_on_ids: [ failed_step.id ]
      )
      collect = Step.create!(
        workflow: workflow,
        kind: COLLECT_KIND,
        position: insertion_position + 1,
        placement_policy: control_plane_policy,
        depends_on_ids: [ prepare.id ],
        details: { "round" => 0, "phase" => "oracle" }
      )
      failed_step.update!(next_step_id: prepare.id)
      prepare.update!(next_step_id: collect.id)
      collect.update!(next_step_id: continuation&.id)
      workflow.set_artifact!(STARTED_ARTIFACT_KEY, {
        "failed_step_id" => failed_step.id,
        "failed_step_kind" => failed_step.kind,
        "started_at" => Time.current.iso8601
      })
      reopen_workflow!
    end

    StepDispatcher.create_run_and_enqueue(prepare, workflow)
    true
  end

  def append_collect_with_evaluations!(after_step:, collect_details:, evaluations:)
    collect = nil
    Step.transaction do
      continuation = after_step.next_step
      insertion_position = after_step.position + 1
      workflow.steps.where("position >= ?", insertion_position).update_all([ "position = position + ?", evaluations.size + 1 ])
      eval_steps = evaluations.each_with_index.map do |details, index|
        Step.create!(
          workflow: workflow,
          kind: EVALUATE_KIND,
          position: insertion_position + index,
          placement_policy: evaluation_policy,
          details: details.deep_stringify_keys,
          depends_on_ids: [ after_step.id ]
        )
      end
      collect = Step.create!(
        workflow: workflow,
        kind: COLLECT_KIND,
        position: insertion_position + evaluations.size,
        placement_policy: control_plane_policy,
        details: collect_details.deep_stringify_keys,
        depends_on_ids: collect_dependency_ids(after_step, eval_steps)
      )
      link_evaluations!(after_step: after_step, eval_steps: eval_steps, collect: collect)
      collect.update!(next_step_id: continuation&.id)
    end
    StepDispatcher.advance_from(after_step)
    collect
  end

  private

  attr_reader :workflow, :train

  def reopen_workflow!
    if workflow.failed? && workflow.may_reopen?
      workflow.reopen!
    elsif workflow.queued? && workflow.may_start?
      workflow.start!
    end
    workflow.save!
  end

  def distributed_workflow_dag_enabled?
    Feature.distributed_workflow_dag_enabled?(workflow.job.repository)
  end

  def control_plane_policy
    distributed_workflow_dag_enabled? ? Step::PlacementPolicy::CONTROL_PLANE : Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
  end

  def evaluation_policy
    distributed_workflow_dag_enabled? ? Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT : Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
  end

  def collect_dependency_ids(after_step, eval_steps)
    return [ after_step.id ] if eval_steps.empty?
    return eval_steps.map(&:id) if distributed_workflow_dag_enabled?

    [ eval_steps.last.id ]
  end

  def link_evaluations!(after_step:, eval_steps:, collect:)
    return after_step.update!(next_step_id: collect.id) if eval_steps.empty?

    if distributed_workflow_dag_enabled?
      after_step.update!(next_step_id: eval_steps.first.id)
      eval_steps.each { |step| step.update!(next_step_id: collect.id) }
      return
    end

    after_step.update!(next_step_id: eval_steps.first.id)
    eval_steps.each_cons(2) do |previous, step|
      step.update!(depends_on_ids: [ previous.id ])
      previous.update!(next_step_id: step.id)
    end
    eval_steps.last.update!(next_step_id: collect.id)
  end
end
