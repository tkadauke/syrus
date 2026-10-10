module Steps
  class MergeTrainMultisectEvaluate < Base
    include MergeTrainStep

    def call
      workspace.setup
      members = merge_train.members.includes(:job).where(id: member_ids).order(:position).to_a
      evaluator = MergeTrainMultisect::FocusedEvaluator.new(
        workflow: workflow,
        train: merge_train,
        workspace_path: workspace.path,
        log: method(:log)
      )
      evaluation = evaluator.call(
        members: members,
        failing_set: MergeTrainMultisect.focused_selector(workflow),
        round: details.fetch("round").to_i,
        role: details.fetch("role")
      )
      result = MergeTrainMultisect.evaluation_payload(evaluation).merge(
        "role" => details.fetch("role"),
        "round" => details.fetch("round").to_i,
        "section_index" => details.fetch("section_index"),
        "members" => MergeTrainMultisect.members_payload(members),
        "evaluated_at" => Time.current.iso8601
      )
      step.update!(details: details.merge("result" => result))
      log("[merge_train_multisect_evaluate] #{result['role']} round #{result['round']} section #{result['section_index']}: #{result['reason']}")
    end

    private

    def details = step.details.to_h

    def member_ids
      Array(details.fetch("member_ids")).map(&:to_i)
    end
  end
end
