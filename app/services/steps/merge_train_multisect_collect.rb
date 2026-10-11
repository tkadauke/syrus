module Steps
  class MergeTrainMultisectCollect < Base
    include MergeTrainMultisectStep

    def call
      skip_reason = multisect_state["skip_reason"].presence
      return abort_multisect!(skip_reason) if skip_reason

      if step.details.to_h["phase"] == "oracle"
        return collect_oracle!
      end

      collect_round!
    end

    private

    def collect_oracle!
      oracle = evaluation_steps(round: 0, role: "oracle").last
      result = oracle && evaluation_result_for(oracle)
      return abort_multisect!("oracle_did_not_reproduce", "oracle" => result) unless result&.fetch("reproduced", false)

      schedule_round!(members_for_ids(multisect_state.fetch("candidate_member_ids")), round: 1)
    end

    def collect_round!
      round = step.details.to_h.fetch("round").to_i
      candidates = members_for_ids(step.details.to_h.fetch("candidate_member_ids"))
      sections = Array(step.details.to_h.fetch("sections"))
      graded_results = evaluation_steps(round: round, role: "section").map do |evaluation_step|
        section_result(evaluation_step)
      end
      reproducing = graded_results.select { |entry| entry.fetch("evaluation").fetch("reproduced", false) }

      if step.details.to_h["phase"] != "omitted_confirmation" && reproducing.one?
        omitted = sections.find { |section| section["omitted"] }
        if omitted
          return schedule_omitted_confirmation!(round: round, sections: sections, reproducing: reproducing.first, omitted: omitted)
        end
      end

      omitted_result = evaluation_steps(round: round, role: "omitted_confirmation").map { |evaluation_step| section_result(evaluation_step) }.last
      reproducing << omitted_result if omitted_result&.fetch("evaluation", {})&.fetch("reproduced", false)
      round_payload = {
        "round" => round,
        "candidate_member_ids" => candidates.map(&:job_id),
        "sections" => sections.map do |section|
          result = (graded_results + Array(omitted_result)).find { |entry| entry.fetch("index") == section.fetch("index") }
          section.merge(
            "reproduced" => result&.fetch("evaluation", {})&.fetch("reproduced", nil),
            "reason" => result&.fetch("evaluation", {})&.fetch("reason", nil),
            "details" => result&.fetch("evaluation", {})&.fetch("details", {})
          ).compact
        end
      }
      rounds = (Array(multisect_state["rounds"]).reject { |entry| entry["round"].to_i == round } + [ round_payload ]).sort_by { |entry| entry["round"].to_i }
      update_multisect_state!("rounds" => rounds)

      return abort_multisect!("multiple_sections_reproduced", "reproducing_section_indexes" => reproducing.map { |entry| entry.fetch("index") }) if reproducing.size > 1
      return abort_multisect!("no_subset_reproduced") unless reproducing.one?

      next_candidates = members_for_ids(reproducing.first.fetch("member_ids"))
      return abort_multisect!("no_subset_reproduced") if next_candidates.empty? || next_candidates.size == candidates.size
      return attribute_member!(next_candidates.first, rounds: rounds) if next_candidates.one?

      schedule_round!(next_candidates, round: round + 1)
    end

    def schedule_round!(candidates, round:)
      sections = MergeTrainMultisect.partition(candidates, multisect_state.fetch("section_width"))
      graded_sections = sections[0...-1]
      section_entries = sections.each_with_index.map do |section, index|
        section_payload(section, index: index, omitted: index == sections.size - 1)
      end
      update_multisect_state!(
        "status" => "running",
        "round" => round,
        "candidate_member_ids" => member_ids_payload(candidates),
        "planned_sections" => section_entries
      )
      log("[merge_train_multisect_collect] scheduling round #{round}: #{graded_sections.size} focused section run(s)")

      materialize_multisect_evaluations!(
        graded_sections.each_with_index.map do |section, index|
          {
            "round" => round,
            "role" => "section",
            "section_index" => index,
            "member_ids" => member_ids_payload(section),
            "candidate_member_ids" => member_ids_payload(candidates),
            "failing_selector" => multisect_state.fetch("failing_selector")
          }
        end,
        collect_details: {
          "round" => round,
          "phase" => "sections",
          "candidate_member_ids" => member_ids_payload(candidates),
          "sections" => section_entries
        }
      )
    end

    def schedule_omitted_confirmation!(round:, sections:, reproducing:, omitted:)
      log("[merge_train_multisect_collect] scheduling omitted-section confirmation for round #{round}")
      materialize_multisect_evaluations!(
        [
          {
            "round" => round,
            "role" => "omitted_confirmation",
            "section_index" => omitted.fetch("index"),
            "member_ids" => omitted.fetch("member_ids"),
            "failing_selector" => multisect_state.fetch("failing_selector")
          }
        ],
        collect_details: step.details.to_h.merge(
          "phase" => "omitted_confirmation",
          "sections" => sections,
          "graded_reproducing_section_index" => reproducing.fetch("index")
        )
      )
    end

    def section_result(evaluation_step)
      {
        "index" => evaluation_step.details.to_h.fetch("section_index").to_i,
        "member_ids" => Array(evaluation_step.details.to_h.fetch("member_ids")),
        "evaluation" => evaluation_result_for(evaluation_step)
      }
    end

    def evaluation_steps(round:, role:)
      workflow.steps
        .where(kind: "merge_train_multisect_evaluate")
        .order(:position)
        .select { |candidate| candidate.details.to_h["round"].to_i == round && candidate.details.to_h["role"] == role }
    end

    def attribute_member!(member, rounds:)
      record_multisect_terminal!(reason: "isolated_member", status: "attributed", attributed_member: member, rounds: rounds)
      fail_with!(:grader_failure, "merge_train_multisect: attributed failure to #{member.job.slug}; record-only rung complete")
    end

    def abort_multisect!(reason, extra = {})
      record_multisect_terminal!(reason: reason, extra: extra)
      fail_with!(:grader_failure, "merge_train_multisect: #{reason}")
    end
  end
end
