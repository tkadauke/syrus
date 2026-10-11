module Steps
  module MergeTrainMultisectStep
    extend ActiveSupport::Concern

    include MergeTrainStep

    STATE_ARTIFACT_KEY = "merge_train_multisect_state".freeze
    STARTED_ARTIFACT_KEY = "merge_train_multisect_continuation_started_at".freeze

    private

    def multisect_state
      workflow.artifact(STATE_ARTIFACT_KEY).to_h
    end

    def update_multisect_state!(attrs)
      workflow.set_artifact!(STATE_ARTIFACT_KEY, multisect_state.deep_merge(attrs.deep_stringify_keys))
    end

    def train_members
      merge_train.members.includes(:job).order(:position).to_a
    end

    def member_ids_payload(members)
      members.map(&:id)
    end

    def members_for_ids(ids)
      by_id = merge_train.members.includes(:job).where(id: ids).index_by(&:id)
      Array(ids).map(&:to_i).filter_map { |id| by_id[id] }
    end

    def section_payload(section, index:, omitted:, evaluation: nil)
      {
        "index" => index,
        "omitted" => omitted,
        "member_ids" => member_ids_payload(section),
        "members" => MergeTrainMultisect.members_payload(section),
        "reproduced" => evaluation&.fetch("reproduced", nil),
        "reason" => evaluation&.fetch("reason", nil),
        "details" => evaluation&.fetch("details", {})
      }.compact
    end

    def materialize_multisect_evaluations!(evaluations, collect_details:)
      continuation = step.next_step
      insertion_position = step.position + 1
      offset = evaluations.size + 1

      Step.transaction do
        workflow.steps.where("position >= ?", insertion_position).update_all(
          [ "position = position + ?", offset ]
        )

        evaluation_steps = evaluations.each_with_index.map do |details, index|
          Step.create!(
            workflow: workflow,
            kind: "merge_train_multisect_evaluate",
            position: insertion_position + index,
            placement_policy: multisect_placement_policy_for("merge_train_multisect_evaluate"),
            details: details.deep_stringify_keys
          )
        end
        collect_step = Step.create!(
          workflow: workflow,
          kind: "merge_train_multisect_collect",
          position: insertion_position + evaluations.size,
          placement_policy: multisect_placement_policy_for("merge_train_multisect_collect"),
          details: collect_details.deep_stringify_keys
        )

        link_multisect_steps!(evaluation_steps, collect_step, continuation)
      end
    end

    def link_multisect_steps!(evaluation_steps, collect_step, continuation)
      evaluation_steps.each { |evaluation| evaluation.update!(depends_on_ids: [ step.id ]) }
      collect_step.update!(depends_on_ids: evaluation_steps.map(&:id).presence || [ step.id ])
      continuation&.update!(depends_on_ids: [ collect_step.id ])

      if distributed_parallel_multisect_projection_enabled?
        step.update!(next_step_id: evaluation_steps.first&.id || collect_step.id)
        evaluation_steps.each { |evaluation| evaluation.update!(next_step_id: collect_step.id) }
      else
        ([ step ] + evaluation_steps + [ collect_step ]).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
      end
      collect_step.update!(next_step_id: continuation&.id)
    end

    def distributed_parallel_multisect_projection_enabled?
      Feature.distributed_workflow_dag_enabled?(repository)
    end

    def multisect_placement_policy_for(kind)
      Step::Kind.fetch(kind).placement_policy_for(repository)
    end

    def evaluation_result_for(step)
      step.details.to_h.fetch("multisect_result", {})
    end

    def multisect_evaluator
      MergeTrainFailureHandler.multisect_evaluator ||
        MergeTrainMultisect::FocusedEvaluator.new(
          workflow: workflow,
          train: merge_train,
          workspace_path: workspace.path,
          log: ->(message, kind: "system") { log(message, kind: kind) }
        )
    end

    def record_multisect_terminal!(reason:, status: "aborted", attributed_member: nil, rounds: nil, extra: {})
      members = train_members
      payload = {
        "status" => status,
        "reason" => reason,
        "section_width" => multisect_state["section_width"],
        "rounds" => rounds || Array(multisect_state["rounds"]),
        "members" => MergeTrainMultisect.members_payload(members),
        "failing_set" => Array(multisect_state["failing_selector"]),
        "recorded_at" => Time.current.iso8601
      }.merge(extra.deep_stringify_keys)
      payload["attributed_member"] = MergeTrainMultisect.member_payload(attributed_member) if attributed_member

      workflow.set_artifact!(MergeTrainMultisect::ARTIFACT_KEY, payload)
      update_multisect_state!("status" => status, "reason" => reason, "finished_at" => Time.current.iso8601)

      if attributed_member
        log("[merge_train_multisect] attributed focused train failure to #{attributed_member.job.slug}")
        member_run = attributed_member.job.current_run || run
        JobLog.append!(
          run: member_run,
          kind: "system",
          chunk: "merge_train: focused multisect attributed the train failure to this member; automatic withdrawal is not enabled."
        )
      else
        log("[merge_train_multisect] aborted: #{reason}")
      end
    end
  end
end
