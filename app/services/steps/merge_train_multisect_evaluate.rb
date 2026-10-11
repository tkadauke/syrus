module Steps
  class MergeTrainMultisectEvaluate < Base
    include MergeTrainMultisectStep

    def call
      members = members_for_ids(step.details.to_h.fetch("member_ids", []))
      selector = Array(step.details.to_h["failing_selector"] || multisect_state["failing_selector"])
      role = step.details.to_h["role"].to_s
      round = step.details.to_h["round"].to_i

      evaluation = multisect_evaluator.call(
        workflow: workflow,
        train: merge_train,
        members: members,
        failing_set: selector,
        round: round,
        role: role
      )
      result = {
        "reproduced" => evaluation.reproduced?,
        "reason" => evaluation.reason,
        "details" => evaluation.details.to_h,
        "evaluated_at" => Time.current.iso8601
      }
      step.update!(details: step.details.to_h.merge("multisect_result" => result))
      log("[merge_train_multisect_evaluate] round #{round} #{role} #{result['reproduced'] ? 'reproduced' : 'did not reproduce'}")
    rescue StandardError => e
      result = {
        "reproduced" => false,
        "reason" => "focused_subset_error",
        "details" => { "error" => "#{e.class}: #{e.message}" },
        "evaluated_at" => Time.current.iso8601
      }
      step.update!(details: step.details.to_h.merge("multisect_result" => result))
      log("[merge_train_multisect_evaluate] #{role.presence || 'section'} failed closed: #{e.class}: #{e.message}")
    end
  end
end
