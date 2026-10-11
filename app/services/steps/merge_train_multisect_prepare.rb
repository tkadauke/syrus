module Steps
  class MergeTrainMultisectPrepare < Base
    include MergeTrainMultisectStep

    def call
      members = train_members
      section_width = MergeTrainMultisect.normalize_section_width(AppSetting.merge_train_multisect_section_width)
      selector = MergeTrainMultisect.focused_selector_for(workflow)
      sections = MergeTrainMultisect.partition(members, section_width)
      base_sha = workflow.artifact("merge_train_base_sha").to_s.presence
      determinism_gate = MergeTrainMultisect::DeterminismGate.new(workflow: workflow, log: ->(message) { log(message) })
      determinism_reproducible = selector.any? && members.size >= 2 && determinism_gate.reproducible?

      state = {
        "status" => "running",
        "selected_rung" => "multisect",
        "candidate_member_ids" => member_ids_payload(members),
        "candidate_train_members" => MergeTrainMultisect.members_payload(members),
        "failing_selector" => selector,
        "base_sha" => base_sha,
        "integration_sha" => merge_train.integration_sha,
        "section_width" => section_width,
        "planned_sections" => sections.each_with_index.map { |section, index| section_payload(section, index: index, omitted: index == sections.size - 1) },
        "oracle" => {
          "determinism_eligible" => determinism_reproducible,
          "determinism" => determinism_gate.payload
        },
        "prepared_at" => Time.current.iso8601
      }

      skip_reason = skip_reason_for(members, selector, determinism_reproducible)
      state["skip_reason"] = skip_reason if skip_reason
      workflow.set_artifact!(STATE_ARTIFACT_KEY, state)
      step.update!(details: step.details.to_h.merge(state.slice(
        "selected_rung", "candidate_train_members", "failing_selector", "base_sha",
        "integration_sha", "section_width", "planned_sections", "oracle", "skip_reason"
      )))
      log("[merge_train_multisect_prepare] selected multisect rung for #{members.size} member(s), width #{section_width}")

      return if skip_reason

      materialize_multisect_evaluations!(
        [
          {
            "round" => 0,
            "role" => "oracle",
            "section_index" => 0,
            "member_ids" => member_ids_payload(members),
            "failing_selector" => selector
          }
        ],
        collect_details: { "round" => 0, "phase" => "oracle" }
      )
    end

    private

    def skip_reason_for(members, selector, determinism_reproducible)
      return "not_enough_members" if members.size < 2
      return "empty_focused_selector" if selector.empty?
      return "flaky_oracle" unless determinism_reproducible

      nil
    end
  end
end
